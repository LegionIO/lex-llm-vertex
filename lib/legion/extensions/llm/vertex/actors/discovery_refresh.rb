# frozen_string_literal: true

require 'digest'
require 'uri'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

require 'legion/extensions/llm/vertex/callable'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Vertex
        module Actor
          # SSOT v3 periodic discovery actor for Vertex AI provider instances.
          # Claims instances, discovers models from STATIC_MODELS catalog, probes
          # health via the non-inference models-list endpoint, and publishes
          # complete OfferingDraft snapshots through the Inventory::Publisher.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Metrics/ClassLength
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              self.class.every_seconds
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
                @initialized = true
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.discovery_refresh.shutdown')
            end

            private

            # -- Publisher -------------------------------------------------------

            def publisher
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vertex)
            end

            # -- Initial discovery -----------------------------------------------

            def initial_discovery
              @instance_states = {}
              configured_instances.each do |name, instance_cfg|
                claim_and_activate_instance(name: name, instance_cfg: instance_cfg)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.claim_instance',
                                    instance_name: name.to_s)
              end
            end

            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = derive_instance_id(instance_cfg: instance_cfg)
              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :vertex, instance_id: instance_id
              )

              callable = VertexCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key,
                enqueue: build_probe_enqueue(instance_id: instance_id)
              )

              publisher_token = publisher.claim_instance(
                instance_id: instance_id,
                callable: callable,
                probe_request_handle: probe_coordinator
              )

              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg, instance_key: instance_key)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: publisher_token
              )

              readiness = check_health(instance_cfg: instance_cfg)

              if readiness.ready?
                publisher.activate_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: publisher_token,
                  offerings: offerings,
                  sequence: 0,
                  probe_token: probe_token
                )
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end

              @instance_states[instance_id] = {
                name: name,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: callable,
                probe_coordinator: probe_coordinator,
                publisher_token: publisher_token,
                sequence: 0,
                offerings: offerings
              }
            end

            # -- Tick refresh ----------------------------------------------------

            def tick_refresh
              @instance_states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.refresh_instance',
                                    instance_id: instance_id)
              end
            end

            def refresh_instance(instance_id:, state:)
              new_offerings = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key]
              )

              if new_offerings != state[:offerings]
                state[:sequence] += 1
                publisher.replace_instance_snapshot(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token],
                  offerings: new_offerings,
                  sequence: state[:sequence]
                )
                state[:offerings] = new_offerings
              end

              run_cadence_probe(instance_id: instance_id, state: state)
            end

            # -- Readiness probing -----------------------------------------------

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              coordinator&.finish_probe rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'vertex.actor.cadence_probe',
                                  instance_id: instance_id)
            end

            def handle_reactive_probe(instance_id:, request:)
              state = @instance_states[instance_id]
              return unless state

              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(
                instance_id: instance_id,
                publisher_token: state[:publisher_token]
              )

              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)

              report_probe_result(instance_id: instance_id, probe_token: probe_token, readiness: readiness)
            rescue StandardError => e
              coordinator&.finish_probe(request: request) rescue nil # rubocop:disable Style/RescueModifier
              handle_exception(e, level: :warn, operation: 'vertex.actor.reactive_probe',
                                  instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:)
              if readiness.ready?
                publisher.readiness_succeeded(instance_id: instance_id, probe_token: probe_token)
              else
                publisher.readiness_failed(
                  instance_id: instance_id,
                  probe_token: probe_token,
                  reason: readiness.reason
                )
              end
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
                true
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.probe_enqueue',
                                    instance_id: instance_id)
                false
              end
            end

            # -- Health check (safe readiness) -----------------------------------
            # Uses GET models list endpoint: non-billable, non-generative control
            # plane operation.

            def check_health(instance_cfg:)
              project = instance_cfg[:vertex_project] || instance_cfg[:project]
              location = instance_cfg[:vertex_location] || instance_cfg[:location] || 'us-central1'
              base_url = vertex_api_base(instance_cfg: instance_cfg, location: location)
              path = "/v1/projects/#{project}/locations/#{location}/publishers/google/models"

              conn = build_health_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get(path)
              build_readiness_from_response(response: response, base_url: base_url)
            rescue Faraday::ConnectionFailed => e
              readiness_failure(reason: "Vertex models-list connection failed: #{e.message}", error: e)
            rescue StandardError => e
              readiness_failure(reason: "Vertex models-list error: #{e.message}", error: e)
            end

            def build_readiness_from_response(response:, base_url:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Vertex models-list returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            end

            def readiness_failure(reason:, error:)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false,
                reason: reason,
                metadata: { error_class: error.class.name }
              )
            end

            # -- Model discovery (static catalog) --------------------------------

            def discover_offerings_for_instance(instance_cfg:, instance_key:)
              models = Provider::STATIC_MODELS
              tier = instance_cfg[:tier] || :cloud

              models.filter_map do |entry|
                model_id = entry[:model].to_s
                next if model_id.empty?

                build_offering_draft(
                  model_entry: entry,
                  tier: tier,
                  instance_cfg: instance_cfg,
                  instance_key: instance_key
                )
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.discover_offerings')
              []
            end

            def build_offering_draft(model_entry:, tier:, instance_cfg:, instance_key:)
              model_id = model_entry[:model]
              is_embedding = model_entry[:usage_type] == :embedding
              is_generate_content = model_entry.fetch(:api, :generate_content) == :generate_content

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: tier,
                operation_evidence: build_operation_evidence(
                  is_embedding: is_embedding, is_generate_content: is_generate_content
                ),
                capability_evidence: build_capability_evidence(
                  model_entry: model_entry, instance_cfg: instance_cfg
                ),
                context_evidence: absent_value_evidence,
                max_output_evidence: absent_value_evidence,
                embedding_dimensions_evidence: absent_value_evidence,
                model_revision_evidence: absent_value_evidence,
                tokenizer_evidence: absent_value_evidence,
                quota_domains: {},
                metadata: build_offering_metadata(model_entry: model_entry, instance_key: instance_key),
                publication_source: :provider_static_catalog
              )
            end

            # -- Operation evidence ----------------------------------------------

            def build_operation_evidence(is_embedding:, is_generate_content:)
              now = Time.now.freeze

              if is_embedding
                build_embedding_operation_evidence(now: now)
              else
                build_chat_operation_evidence(now: now, is_generate_content: is_generate_content)
              end
            end

            def build_chat_operation_evidence(now:, is_generate_content:)
              count_tokens_status = is_generate_content ? :supported : :unsupported
              {
                chat: op_evidence(operation: :chat, status: :supported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: :supported, observed_at: now),
                embed: op_evidence(operation: :embed, status: :unsupported, observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: count_tokens_status, observed_at: now)
              }
            end

            def build_embedding_operation_evidence(now:)
              {
                chat: op_evidence(operation: :chat, status: :unsupported, observed_at: now),
                stream_chat: op_evidence(operation: :stream_chat, status: :unsupported, observed_at: now),
                embed: op_evidence(operation: :embed, status: :supported, observed_at: now),
                image: op_evidence(operation: :image, status: :unsupported, observed_at: now),
                transcribe: op_evidence(operation: :transcribe, status: :unsupported, observed_at: now),
                translate: op_evidence(operation: :translate, status: :unsupported, observed_at: now),
                speak: op_evidence(operation: :speak, status: :unsupported, observed_at: now),
                moderate: op_evidence(operation: :moderate, status: :unsupported, observed_at: now),
                count_tokens: op_evidence(operation: :count_tokens, status: :unsupported, observed_at: now)
              }
            end

            def op_evidence(operation:, status:, observed_at:)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation,
                status: status,
                source: source,
                observed_at: observed_at
              )
            end

            # -- Capability evidence ---------------------------------------------

            def build_capability_evidence(model_entry:, instance_cfg:)
              is_embedding = model_entry[:usage_type] == :embedding

              if is_embedding
                build_embedding_capability_evidence
              else
                build_chat_capability_evidence(model_entry: model_entry, instance_cfg: instance_cfg)
              end
            end

            def build_chat_capability_evidence(model_entry:, instance_cfg:)
              {
                completion: cap_evidence(
                  capability: :completion, status: :supported, source: :provider_implementation
                ),
                streaming: cap_evidence(
                  capability: :streaming, status: :supported, source: :provider_implementation
                ),
                vision: resolve_vision_evidence(instance_cfg: instance_cfg),
                tools: resolve_tools_evidence(model_entry: model_entry, instance_cfg: instance_cfg),
                thinking: resolve_thinking_evidence(instance_cfg: instance_cfg)
              }
            end

            def build_embedding_capability_evidence
              {
                embedding: cap_evidence(
                  capability: :embedding, status: :supported, source: :provider_implementation
                )
              }
            end

            def cap_evidence(capability:, status:, source:)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability,
                status: status,
                source: source,
                observed_at: Time.now.freeze
              )
            end

            def resolve_vision_evidence(instance_cfg:)
              if instance_cfg.key?(:enable_vision)
                return cap_evidence(capability: :vision, status: :unknown, source: :instance_override)
              end

              cap_evidence(capability: :vision, status: :unknown, source: :default_false)
            end

            def resolve_tools_evidence(model_entry:, instance_cfg:) # rubocop:disable Lint/UnusedMethodArgument
              if instance_cfg.key?(:enable_tools)
                return cap_evidence(capability: :tools, status: :unknown, source: :instance_override)
              end

              cap_evidence(capability: :tools, status: :unknown, source: :default_false)
            end

            def resolve_thinking_evidence(instance_cfg:)
              if instance_cfg.key?(:enable_thinking)
                return cap_evidence(capability: :thinking, status: :unknown, source: :instance_override)
              end

              cap_evidence(capability: :thinking, status: :unknown, source: :default_false)
            end

            # -- Value evidence --------------------------------------------------

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(
                status: :unknown, source: :absent
              )
            end

            # -- Offering metadata -----------------------------------------------

            def build_offering_metadata(model_entry:, instance_key:)
              {
                raw_model: model_entry[:model],
                publisher: model_entry[:publisher],
                model_family: model_entry[:model_family].to_s,
                api: model_entry.fetch(:api, :generate_content).to_s,
                instance_id: instance_key.instance_id
              }.freeze
            end

            # -- Instance ID derivation ------------------------------------------
            # Format: {project}:{location}/{credential_fingerprint}

            def derive_instance_id(instance_cfg:)
              project = instance_cfg[:vertex_project] || instance_cfg[:project] || 'unknown'
              location = instance_cfg[:vertex_location] || instance_cfg[:location] || 'us-central1'
              fingerprint = credential_fingerprint(instance_cfg: instance_cfg)
              "#{project}:#{location}/#{fingerprint}"
            end

            def credential_fingerprint(instance_cfg:)
              token = instance_cfg[:vertex_access_token] || instance_cfg[:access_token]
              creds = instance_cfg[:vertex_credentials] || instance_cfg[:credentials]
              material = (token || creds).to_s
              return 'no-cred' if material.empty?

              ::Digest::SHA256.hexdigest(material)[0, 6]
            end

            # -- Graceful shutdown -----------------------------------------------

            def remove_all_instances
              return unless @instance_states

              @instance_states.each do |instance_id, state|
                publisher.remove_instance(
                  instance_id: instance_id,
                  publisher_token: state[:publisher_token]
                )
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.remove_instance',
                                    instance_id: instance_id)
              end
              @instance_states.clear
            end

            # -- Configuration ---------------------------------------------------

            def configured_instances
              instances = {}

              cfg_instances = settings[:instances]
              if cfg_instances.is_a?(Hash)
                cfg_instances.each do |name, config|
                  instances[name.to_sym] = normalize_instance_config(config: config)
                end
              end

              # Fallback to top-level settings if no named instances
              if instances.empty?
                top_level = build_top_level_instance
                instances[:default_instance] = top_level if top_level
              end

              instances
            end

            def build_top_level_instance
              project = settings[:project]
              return nil unless project.is_a?(String) && !project.strip.empty?

              {
                vertex_project: project,
                vertex_location: settings[:location] || 'us-central1',
                vertex_access_token: settings[:access_token],
                vertex_credentials: settings[:credentials],
                tier: :cloud
              }.compact
            end

            def normalize_instance_config(config:)
              normalized = config.to_h.transform_keys(&:to_sym)
              normalized[:vertex_project] ||= normalized.delete(:project)
              normalized[:vertex_location] ||= normalized.delete(:location)
              normalized[:vertex_api_base] ||= normalized.delete(:base_url)
              normalized[:vertex_api_base] ||= normalized.delete(:api_base)
              normalized[:vertex_api_base] ||= normalized.delete(:endpoint)
              normalized[:vertex_access_token] ||= normalized.delete(:access_token)
              normalized[:vertex_credentials] ||= normalized.delete(:credentials)
              normalized[:tier] ||= :cloud
              normalized
            end

            # -- HTTP connections ------------------------------------------------

            def vertex_api_base(instance_cfg:, location:)
              instance_cfg[:vertex_api_base] || "https://#{location}-aiplatform.googleapis.com"
            end

            def build_health_connection(base_url:, instance_cfg:)
              require 'faraday'
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 10
                f.options.open_timeout = 5
                apply_auth_header(faraday: f, instance_cfg: instance_cfg)
                f.adapter Faraday.default_adapter
              end
            end

            def apply_auth_header(faraday:, instance_cfg:)
              token = instance_cfg[:vertex_access_token] || instance_cfg[:access_token]
              return unless token.is_a?(String) && !token.strip.empty?

              faraday.headers['Authorization'] = "Bearer #{token}"
            end
          end
        end
      end
    end
  end
end
