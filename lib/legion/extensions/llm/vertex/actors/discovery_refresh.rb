# frozen_string_literal: true

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

unless defined?(Legion::Extensions::Actors::Every)
  raise LoadError, 'LegionIO actor runtime is required for Vertex discovery refresh'
end

require 'concurrent'
require 'faraday'
require 'legion/extensions/llm/vertex/callable'
require 'legion/extensions/llm/inventory/publisher'
require 'legion/extensions/llm/inventory/identity'
require 'legion/extensions/llm/inventory/records'
require 'legion/extensions/llm/inventory/weight_reconciler'
require 'legion/extensions/llm/inventory/evidence'
require 'legion/extensions/llm/inventory/probe_coordinator'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/taxonomies'
require 'legion/extensions/llm/capabilities'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Actor
          # Operation evidence constructors for DiscoveryRefresh.
          module DiscoveryRefreshOperationEvidence
            private

            def build_operation_evidence(now:, is_embedding:, is_generate_content:)
              if is_embedding
                build_embedding_op_evidence(now: now)
              else
                build_chat_op_evidence(now: now, is_gen: is_generate_content)
              end
            end

            def build_chat_op_evidence(now:, is_gen:)
              ct_status = is_gen ? :supported : :unsupported
              {
                chat: op_ev(:chat, :supported, now), stream_chat: op_ev(:stream_chat, :supported, now),
                embed: op_ev(:embed, :unsupported, now), image: op_ev(:image, :unsupported, now),
                transcribe: op_ev(:transcribe, :unsupported, now), translate: op_ev(:translate, :unsupported, now),
                speak: op_ev(:speak, :unsupported, now), moderate: op_ev(:moderate, :unsupported, now),
                count_tokens: op_ev(:count_tokens, ct_status, now)
              }
            end

            def build_embedding_op_evidence(now:)
              {
                chat: op_ev(:chat, :unsupported, now), stream_chat: op_ev(:stream_chat, :unsupported, now),
                embed: op_ev(:embed, :supported, now), image: op_ev(:image, :unsupported, now),
                transcribe: op_ev(:transcribe, :unsupported, now), translate: op_ev(:translate, :unsupported, now),
                speak: op_ev(:speak, :unsupported, now), moderate: op_ev(:moderate, :unsupported, now),
                count_tokens: op_ev(:count_tokens, :unsupported, now)
              }
            end

            def op_ev(operation, status, observed_at)
              source = status == :unknown ? :default_false : :provider_implementation
              Legion::Extensions::Llm::Inventory::OperationEvidence.new(
                operation: operation, status: status, source: source, observed_at: observed_at
              )
            end
          end

          # Capability evidence constructors for DiscoveryRefresh.
          module DiscoveryRefreshCapabilityEvidence
            private

            def build_capability_evidence(model_entry:, instance_cfg:, now:)
              if model_entry[:usage_type] == :embedding
                build_embedding_cap_evidence(now: now)
              else
                build_chat_cap_evidence(instance_cfg: instance_cfg, now: now)
              end
            end

            def build_chat_cap_evidence(instance_cfg:, now:)
              {
                completion: cap_ev(:completion, :supported, :provider_implementation, now),
                streaming: cap_ev(:streaming, :supported, :provider_implementation, now),
                vision: resolve_vision_evidence(instance_cfg: instance_cfg, now: now),
                tools: resolve_tools_evidence(instance_cfg: instance_cfg, now: now),
                thinking: resolve_thinking_evidence(instance_cfg: instance_cfg, now: now)
              }
            end

            def build_embedding_cap_evidence(now:)
              { embedding: cap_ev(:embedding, :supported, :provider_implementation, now) }
            end

            def cap_ev(capability, status, source, now)
              Legion::Extensions::Llm::Inventory::CapabilityEvidence.new(
                capability: capability, status: status, source: source, observed_at: now
              )
            end

            def resolve_vision_evidence(instance_cfg:, now:)
              src = instance_cfg.key?(:enable_vision) ? :instance_override : :default_false
              cap_ev(:vision, :unknown, src, now)
            end

            def resolve_tools_evidence(instance_cfg:, now:)
              src = instance_cfg.key?(:enable_tools) ? :instance_override : :default_false
              cap_ev(:tools, :unknown, src, now)
            end

            def resolve_thinking_evidence(instance_cfg:, now:)
              src = instance_cfg.key?(:enable_thinking) ? :instance_override : :default_false
              cap_ev(:thinking, :unknown, src, now)
            end

            def absent_value_evidence
              Legion::Extensions::Llm::Inventory::ValueEvidence.new(status: :unknown, source: :absent)
            end

            def build_offering_metadata(model_entry:, instance_key:)
              {
                raw_model: model_entry[:model],
                publisher: model_entry[:publisher],
                model_family: model_entry[:model_family].to_s,
                api: model_entry.fetch(:api, :generate_content).to_s,
                instance_id: instance_key.instance_id
              }.freeze
            end
          end

          # Configuration and identity helpers for DiscoveryRefresh.
          module DiscoveryRefreshConfigHelpers
            private

            # Single source of truth for configured Vertex instances: the entry
            # module's discovery, which applies the project/credential filter
            # (Vertex.vertex_credentials_present?) and normalizes keys.
            def configured_instances
              Legion::Extensions::Llm::Vertex.discover_instances
            end

            # Derives the SECONDARY physical identity (project:location/
            # credential-fingerprint) carried as InstanceKey#physical_id for
            # dedup and diagnostics. It is NOT the instance identity — the
            # identity is the operator's config name (see
            # claim_and_activate_instance).
            #
            # Returns nil instead of a fallback: an instance without a
            # resolvable project or credential is skipped by the caller. It is
            # never claimed under a provider-fallback identity (no
            # "unknown"/"default"/"no-cred" IDs).
            def derive_physical_id(instance_cfg:)
              project = instance_cfg[:vertex_project] || instance_cfg[:project]
              return nil if project.nil? || project.to_s.strip.empty?

              fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint(
                instance_cfg[:vertex_access_token] || instance_cfg[:vertex_credentials] ||
                  instance_cfg[:access_token] || instance_cfg[:credentials]
              )
              return nil if fingerprint.nil?

              location = instance_cfg[:vertex_location] || instance_cfg[:location] || 'us-central1'
              "#{project}:#{location}/#{fingerprint}"
            end

            def vertex_api_base(instance_cfg:, location:)
              instance_cfg[:vertex_api_base] || "https://#{location}-aiplatform.googleapis.com"
            end

            def build_health_connection(base_url:, instance_cfg:)
              Faraday.new(url: base_url) do |f|
                f.options.timeout = 10
                f.options.open_timeout = 5
                token = instance_cfg[:vertex_access_token] || instance_cfg[:access_token]
                f.headers['Authorization'] = "Bearer #{token}" if token.is_a?(String) && !token.strip.empty?
                f.adapter Faraday.default_adapter
              end
            end
          end

          # Readiness probe and health check helpers for DiscoveryRefresh.
          module DiscoveryRefreshProbeHelpers
            private

            def run_cadence_probe(instance_id:, state:)
              coordinator = state[:probe_coordinator]
              return unless coordinator.begin_probe

              probe_token = publisher.readiness_probe_started(instance_id: instance_id,
                                                              publisher_token: state[:publisher_token],
                                                              physical_id: state[:physical_id])
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe
              report_probe_result(instance_id: instance_id, probe_token: probe_token,
                                  readiness: readiness, state: state)
            rescue StandardError => e
              begin
                coordinator&.finish_probe
              rescue StandardError => finish_e
                handle_exception(finish_e, level: :warn, operation: 'vertex.actor.cadence_probe.finish_probe')
              end
              handle_exception(e, level: :warn, operation: 'vertex.actor.cadence_probe', instance_id: instance_id)
            end

            def report_probe_result(instance_id:, probe_token:, readiness:, state:)
              if readiness.ready?
                published = @state_mutex.synchronize do
                  @instance_states[instance_id].equal?(state) && state[:published]
                end
                settled = if published
                            @state_mutex.synchronize do
                              next false unless @instance_states[instance_id].equal?(state) && state[:published]

                              publisher.readiness_succeeded(
                                instance_id: instance_id,
                                probe_token: probe_token,
                                physical_id: state[:physical_id]
                              )
                              true
                            end
                          else
                            activate_tracked_instance(
                              instance_id: instance_id,
                              state: state,
                              probe_token: probe_token
                            )
                          end
              else
                settled = @state_mutex.synchronize do
                  next false unless @instance_states[instance_id].equal?(state)

                  publisher.readiness_failed(
                    instance_id: instance_id,
                    probe_token: probe_token,
                    reason: readiness.reason,
                    physical_id: state[:physical_id]
                  )
                  true
                end
              end
              if settled
                sync_instance_health(
                  name: state[:name], instance_key: state[:instance_key], offerings: state[:offerings]
                )
              end
              settled
            end

            def check_health(instance_cfg:)
              project = instance_cfg[:vertex_project] || instance_cfg[:project]
              location = instance_cfg[:vertex_location] || instance_cfg[:location] || 'us-central1'
              base_url = vertex_api_base(instance_cfg: instance_cfg, location: location)
              path = "/v1/projects/#{project}/locations/#{location}/publishers/google/models"
              conn = build_health_connection(base_url: base_url, instance_cfg: instance_cfg)
              response = conn.get(path)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Vertex models-list returned #{response.status}",
                metadata: { status: response.status, base_url: base_url }
              )
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.check_health')
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: false, reason: "Vertex models-list error: #{e.message}",
                metadata: { error_class: e.class.name }
              )
            end
          end

          # Request-triggered readiness probes use the same tracked state and
          # publication result path as the periodic cadence probe.
          module DiscoveryRefreshReactiveProbeHelpers
            private

            def handle_reactive_probe(instance_id:, request:)
              return false if @instance_states.nil?

              state = @state_mutex.synchronize { @instance_states[instance_id] }
              return false unless state

              coordinator = state[:probe_coordinator]
              return false unless coordinator.begin_probe(request: request)

              probe_token = publisher.readiness_probe_started(instance_id: instance_id,
                                                              publisher_token: state[:publisher_token],
                                                              physical_id: state[:physical_id])
              readiness = check_health(instance_cfg: state[:instance_cfg])
              coordinator.finish_probe(request: request)
              report_probe_result(instance_id: instance_id, probe_token: probe_token,
                                  readiness: readiness, state: state)
              true
            rescue StandardError => e
              begin
                coordinator&.finish_probe(request: request)
              rescue StandardError => finish_e
                handle_exception(finish_e, level: :warn, operation: 'vertex.actor.reactive_probe.finish_probe')
              end
              handle_exception(e, level: :warn, operation: 'vertex.actor.reactive_probe', instance_id: instance_id)
              false
            end

            def build_probe_enqueue(instance_id:)
              proc do |request:|
                handle_reactive_probe(instance_id: instance_id, request: request)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.probe_enqueue', instance_id: instance_id)
                false
              end
            end
          end

          # Offering snapshot construction helpers for DiscoveryRefresh.
          module DiscoveryRefreshOfferingHelpers
            private

            # The catalog is static per instance, so evidence timestamps are
            # pinned per instance (state[:evidence_now]) — rebuilding with a
            # fresh Time.now would make every draft unequal and force a
            # replace_instance_snapshot churn on every tick.
            def discover_offerings_for_instance(instance_cfg:, instance_key:, now:)
              tier = instance_cfg[:tier] || :cloud
              Provider::STATIC_MODELS.filter_map do |entry|
                next if entry[:model].to_s.empty?

                build_offering_draft(model_entry: entry, tier: tier, instance_cfg: instance_cfg,
                                     instance_key: instance_key, now: now)
              end
            rescue ArgumentError
              raise
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.discover_offerings')
              []
            end

            def build_offering_draft(model_entry:, tier:, instance_cfg:, instance_key:, now:)
              model_id = model_entry[:model]
              is_embedding = model_entry[:usage_type] == :embedding
              is_gen = model_entry.fetch(:api, :generate_content) == :generate_content
              weight_inputs = Legion::Extensions::Llm::Inventory::WeightSchema.weight_inputs(
                settings: Legion::Settings,
                instance_key: instance_key,
                provider_native_key: model_id,
                model: model_id,
                tier: tier
              )
              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id, model: model_id, tier: tier,
                weight_inputs: weight_inputs,
                base_weight: Legion::Extensions::Llm::Inventory::WeightSchema.base_weight(weight_inputs),
                operation_evidence: build_operation_evidence(now: now,
                                                             is_embedding: is_embedding,
                                                             is_generate_content: is_gen),
                capability_evidence: build_capability_evidence(model_entry: model_entry,
                                                               instance_cfg: instance_cfg, now: now),
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
          end

          # Atomic weight publication adapters and dormant observation used by
          # the existing Vertex discovery cadence. The shared reconciler owns
          # sequence and cache mutation.
          module DiscoveryRefreshWeightPublication
            private

            def replace_offerings_if_changed(instance_id:, state:)
              discovered = discover_offerings_for_instance(
                instance_cfg: state[:instance_cfg],
                instance_key: state[:instance_key],
                now: state[:evidence_now]
              )
              changed = Legion::Extensions::Llm::Inventory::WeightReconciler.commit_if_changed!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state: state,
                discovered_offerings: discovered,
                mutex: @state_mutex,
                equivalent: ->(previous, current) { previous == current },
                replace: method(:replace_weight_snapshot)
              )
              published = @state_mutex.synchronize do
                @instance_states[instance_id].equal?(state) && state[:published]
              end
              if changed && published
                sync_instance_health(
                  name: state[:name], instance_key: state[:instance_key], offerings: state[:offerings]
                )
              end
              changed
            end

            def replace_weight_snapshot(instance_id:, state:, offerings:, sequence:)
              publisher.replace_instance_snapshot(
                instance_id: instance_id,
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                physical_id: state.fetch(:physical_id)
              )
            end

            def activate_tracked_instance(instance_id:, state:, probe_token:)
              Legion::Extensions::Llm::Inventory::WeightReconciler.activate_tracked!(
                settings: Legion::Settings,
                instance_id: instance_id,
                state_key: instance_id,
                state: state,
                states: @instance_states,
                mutex: @state_mutex,
                probe_token: probe_token,
                activate: method(:activate_weight_snapshot),
                activation_sequence: ->(tracked) { tracked.fetch(:sequence) }
              )
            end

            def activate_weight_snapshot(instance_id:, state:, offerings:, sequence:, probe_token:)
              publisher.activate_instance_snapshot(
                instance_id: instance_id,
                publisher_token: state.fetch(:publisher_token),
                offerings: offerings,
                sequence: sequence,
                probe_token: probe_token,
                physical_id: state.fetch(:physical_id)
              )
            end

            def observe_dormant_weights
              Legion::Extensions::Llm::Inventory::WeightReconciler.observe_dormant!(
                settings: Legion::Settings,
                provider_family: :vertex,
                states: @instance_states,
                mutex: @state_mutex,
                tracker: @dormant_weight_tracker,
                dormant_logger: lambda do |key|
                  log.info do
                    "[llm][vertex] action=dormant_weight weight_key=#{key.inspect} no_lane_published=true"
                  end
                end
              )
            end
          end

          # Publisher, tick-refresh, and instance removal orchestration for
          # DiscoveryRefresh.
          module DiscoveryRefreshLifecycleHelpers
            private

            def publisher
              # 0.8.0: the mixed-version window is over — the legacy
              # old-coordinator projection bridge is gone with the lex-llm
              # cut; the Publisher is a direct Registry wrapper only.
              @publisher ||= Legion::Extensions::Llm::Inventory::Publisher.new(provider_family: :vertex)
            end

            def initial_discovery
              @instance_states = Concurrent::Map.new
              @state_mutex = Mutex.new
              @dormant_weight_tracker = Legion::Extensions::Llm::Inventory::DormantWeightTracker.new
              @initialized = true
              reconcile_instances
              observe_dormant_weights
            end

            # Re-scans configured instances each tick so late-configured
            # instances appear without a restart and removed instances are
            # retired (with their display health cleared).
            # Instance identity is the operator's CONFIG NAME (the key the
            # router's instances.<name> settings lookups use); names are
            # unique by construction, so two names pointing at the same
            # physical endpoint stay distinct instances (the derived
            # physical_id is diagnostic, never a dedup key that collapses
            # operator-named instances).
            def reconcile_instances
              desired = {}
              configured_instances.each do |name, instance_cfg|
                physical_id = derive_physical_id(instance_cfg: instance_cfg)
                if physical_id.nil?
                  log.warn(
                    "[vertex][actor] action=skip_instance name=#{name} " \
                    'reason=no_resolvable_project_or_credential'
                  )
                  next
                end

                desired[name.to_s] = { name: name, instance_cfg: instance_cfg }
              end

              desired.each do |instance_id, entry|
                tracked = @state_mutex.synchronize { @instance_states.key?(instance_id) }
                next if tracked

                claim_and_activate_instance(name: entry[:name], instance_cfg: entry[:instance_cfg])
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.claim_instance',
                                    instance_name: entry[:name].to_s)
              end

              tracked_ids = @state_mutex.synchronize { @instance_states.keys }
              (tracked_ids - desired.keys).each do |instance_id|
                remove_instance_state(instance_id)
              end
            end

            def tick_refresh
              reconcile_instances
              states = @state_mutex.synchronize { @instance_states.each_pair.to_a }
              states.each do |instance_id, state|
                refresh_instance(instance_id: instance_id, state: state)
              rescue StandardError => e
                handle_exception(e, level: :warn, operation: 'vertex.actor.refresh_instance',
                                    instance_id: instance_id)
              end
              observe_dormant_weights
            end

            def refresh_instance(instance_id:, state:)
              replace_offerings_if_changed(instance_id: instance_id, state: state)
              run_cadence_probe(instance_id: instance_id, state: state)
            end

            def remove_instance_state(instance_id)
              state = @state_mutex.synchronize do
                tracked = @instance_states[instance_id]
                next unless tracked

                publisher.remove_instance(
                  instance_id: instance_id,
                  publisher_token: tracked[:publisher_token],
                  physical_id: tracked[:physical_id]
                )
                tracked[:published] = false
                @instance_states.delete(instance_id)
                tracked
              end
              return unless state

              state[:callable].disconnect
              clear_instance_health(name: state[:name])
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.remove_instance',
                                  instance_id: instance_id)
            end

            def remove_all_instances
              return unless @instance_states

              instance_ids = @state_mutex.synchronize { @instance_states.keys }
              instance_ids.each { |instance_id| remove_instance_state(instance_id) }
              @state_mutex.synchronize do
                @instance_states.clear
                @dormant_weight_tracker.clear!
              end
            end
          end

          # Instance claim and initial-readiness activation helpers for
          # DiscoveryRefresh.
          module DiscoveryRefreshClaimHelpers
            private

            # Instance identity is the operator's CONFIG NAME (the key the
            # router's instances.<name> lookups use). The derived
            # project:location/fingerprint rides along as the secondary
            # physical_id field for dedup and diagnostics only.
            def claim_and_activate_instance(name:, instance_cfg:)
              instance_id = name.to_s
              physical_id = derive_physical_id(instance_cfg: instance_cfg)
              raise ArgumentError, 'claim_and_activate_instance requires a resolvable physical_id' if physical_id.nil?

              instance_key = Legion::Extensions::Llm::Inventory::Identity::InstanceKey.new(
                provider_family: :vertex, instance_id: instance_id, physical_id: physical_id
              )
              now = Time.now.freeze
              offerings = discover_offerings_for_instance(instance_cfg: instance_cfg,
                                                          instance_key: instance_key, now: now)
              callable = VertexCallable.new(instance_cfg: instance_cfg, logger: log)
              probe_coordinator = Legion::Extensions::Llm::Inventory::ProbeCoordinator.new(
                instance_key: instance_key, enqueue: build_probe_enqueue(instance_id: instance_id)
              )
              pub_token = publisher.claim_instance(instance_id: instance_id, callable: callable,
                                                   probe_request_handle: probe_coordinator, physical_id: physical_id)
              state = {
                name: name,
                instance_key: instance_key,
                instance_cfg: instance_cfg,
                callable: callable,
                probe_coordinator: probe_coordinator,
                publisher_token: pub_token,
                sequence: 0,
                offerings: offerings,
                evidence_now: now,
                physical_id: physical_id
              }
              Legion::Extensions::Llm::Inventory::WeightReconciler.track_initializing!(
                states: @instance_states,
                state_key: instance_id,
                state: state,
                mutex: @state_mutex
              )
              probe_token = publisher.readiness_probe_started(instance_id: instance_id, publisher_token: pub_token,
                                                              physical_id: physical_id)
              settled = activate_or_fail_instance(
                instance_id: instance_id,
                probe_token: probe_token,
                state: state
              )
              return unless settled

              sync_instance_health(
                name: name, instance_key: instance_key, offerings: state[:offerings]
              )
            end

            def activate_or_fail_instance(instance_id:, probe_token:, state:)
              readiness = check_health(instance_cfg: state[:instance_cfg])
              if readiness.ready?
                activate_tracked_instance(instance_id: instance_id, state: state, probe_token: probe_token)
              else
                @state_mutex.synchronize do
                  next false unless @instance_states[instance_id].equal?(state)

                  publisher.readiness_failed(
                    instance_id: instance_id,
                    probe_token: probe_token,
                    reason: readiness.reason,
                    physical_id: state[:physical_id]
                  )
                  true
                end
              end
            end
          end

          # Display-only health/capabilities settings for DiscoveryRefresh,
          # written AFTER each registry commit. Legacy 4-key health shape
          # (circuit_state/denied/available/adjustment) so pre-SSOT consumers
          # see unchanged output, plus display-only provenance fields.
          # Display only — routing authority stays the in-memory
          # AvailabilityFact.
          module DiscoveryRefreshHealthDisplay
            HEALTH_ADJUSTMENT_AVAILABLE = 0
            HEALTH_ADJUSTMENT_DEGRADED = -50
            CAPABILITY_NAMES_BY_OPERATION = {
              chat: :completion, stream_chat: :streaming, embed: :embedding, image: :image,
              transcribe: :audio_transcription, translate: :audio_transcription, speak: :audio_speech,
              moderate: :moderation
            }.freeze

            private

            def sync_instance_health(name:, instance_key:, offerings:)
              snapshot = publisher.snapshot
              status = snapshot.publication_status(instance_key: instance_key)
              record = snapshot.instance(instance_key: instance_key)
              availability = record&.availability
              available = availability&.state == :available

              instances_settings = settings[:instances] || (settings[:instances] = {})
              instance_settings = instances_settings[name] || (instances_settings[name] = {})
              instance_settings[:health] = {
                circuit_state: circuit_state_for(availability),
                denied: false,
                available: available,
                adjustment: available ? HEALTH_ADJUSTMENT_AVAILABLE : HEALTH_ADJUSTMENT_DEGRADED,
                reason: availability&.reason || status.last_error,
                observed_at: observed_at_display(availability),
                last_probe_outcome: status.last_probe_outcome,
                source: :ssot_discovery_actor
              }.compact
              instance_settings[:capabilities] = supported_capabilities(offerings)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.sync_health',
                                  instance_id: instance_key.instance_id)
            end

            def clear_instance_health(name:)
              instance_settings = settings[:instances][name]
              return unless instance_settings.is_a?(Hash)

              instance_settings.delete(:health)
              instance_settings.delete(:capabilities)
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.clear_health',
                                  instance_name: name.to_s)
            end

            def circuit_state_for(availability)
              case availability&.state
              when :available then :closed
              when :unavailable then :open
              else :half_open
              end
            end

            def supported_capabilities(offerings)
              capabilities = []
              offerings.each do |draft|
                draft.operation_evidence.each do |operation, evidence|
                  next unless evidence.status == :supported

                  cap = CAPABILITY_NAMES_BY_OPERATION.fetch(operation, operation)
                  capabilities << cap unless capabilities.include?(cap)
                end
                draft.capability_evidence.each do |capability, evidence|
                  capabilities << capability if evidence.status == :supported && !capabilities.include?(capability)
                end
              end
              capabilities.sort
            end

            def observed_at_display(availability)
              observed_at = availability&.observed_at
              return nil unless observed_at

              observed_at.getutc.strftime('%Y-%m-%dT%H:%M:%SZ')
            end
          end

          # SSOT v3 periodic discovery actor for Vertex AI provider instances.
          # Claims configured instances, discovers models from the STATIC_MODELS
          # catalog, probes health via the non-inference models-list endpoint,
          # and publishes complete OfferingDraft snapshots through the
          # Inventory::Publisher. Owns the refresh cadence, recovers
          # initial-readiness failures, and writes the display-only
          # health/capabilities settings after each registry commit.
          class DiscoveryRefresh < Legion::Extensions::Actors::Every
            include Legion::Extensions::Helpers::Lex
            include Legion::Logging::Helper
            include DiscoveryRefreshOperationEvidence
            include DiscoveryRefreshCapabilityEvidence
            include DiscoveryRefreshConfigHelpers
            include DiscoveryRefreshProbeHelpers
            include DiscoveryRefreshReactiveProbeHelpers
            include DiscoveryRefreshOfferingHelpers
            include DiscoveryRefreshWeightPublication
            include DiscoveryRefreshClaimHelpers
            include DiscoveryRefreshHealthDisplay
            include DiscoveryRefreshLifecycleHelpers

            # Guards a broken discovery config (missing or non-positive value);
            # the registered default (lex-llm ProviderSettings) is 300 seconds.
            FALLBACK_DISCOVERY_INTERVAL_SECONDS = 300

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            # The actor owns the discovery cadence. Read the registered
            # interval so the operator knob is honored and the timer never
            # receives nil.
            def time
              interval = settings.dig(:discovery, :interval_seconds)
              interval.is_a?(Numeric) && interval.positive? ? interval : FALLBACK_DISCOVERY_INTERVAL_SECONDS
            end

            def manual
              if @initialized
                tick_refresh
              else
                initial_discovery
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.discovery_refresh')
            end

            def shutdown
              remove_all_instances
            rescue StandardError => e
              handle_exception(e, level: :warn, operation: 'vertex.actor.discovery_refresh.shutdown')
            end
          end
        end
      end
    end
  end
end
