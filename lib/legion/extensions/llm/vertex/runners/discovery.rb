# frozen_string_literal: true

require 'time'
require 'faraday'

require 'legion/extensions/llm/discovery/pipeline'
require 'legion/extensions/llm/vertex/helpers/callable'
require 'legion/extensions/llm/vertex/provider'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Runners
          # Vertex discovery runner: ONLY the Vertex-specific work. The generic
          # reconcile / claim / activate / probe (cadence + reactive) / replace /
          # weight-publication / health-display pipeline is mixed in from the
          # shared Discovery::Pipeline. Weight is NOT computed here — the shared
          # WeightReconciler recomputes it from live settings at publish.
          #
          # The catalog is the provider's STATIC_MODELS list (no HTTP endpoint),
          # served by fetch_raw_models. The overrides are the Vertex API base
          # (per project location), the bearer OAuth access token, the
          # per-project models-list readiness, the project:location/credential
          # physical id, and the offering-draft evidence.
          module Discovery
            extend self
            include Legion::Extensions::Llm::Discovery::Pipeline

            # ── Vertex instance-config keys / connection ─────────────────────
            def catalog_base_url(instance_cfg:)
              instance_cfg[:vertex_api_base] || "https://#{vertex_location(instance_cfg)}-aiplatform.googleapis.com"
            end

            # Vertex authenticates with a bearer OAuth access token.
            def auth_token(instance_cfg:)
              token = instance_cfg[:vertex_access_token] || instance_cfg[:access_token]
              token if token.is_a?(String) && !token.strip.empty?
            end

            # Readiness is a safe non-inference GET of the project's models list
            # (the path is per instance: project + location).
            def check_health(instance_cfg:)
              project = vertex_project(instance_cfg)
              location = vertex_location(instance_cfg)
              path = "/v1/projects/#{project}/locations/#{location}/publishers/google/models"
              conn = build_connection(base_url: catalog_base_url(instance_cfg: instance_cfg),
                                      instance_cfg: instance_cfg, timeout: 10, open_timeout: 5)
              response = conn.get(path)
              Legion::Extensions::Llm::Inventory::ReadinessResult.new(
                ready: response.status == 200,
                reason: "Vertex models-list returned #{response.status}",
                metadata: { status: response.status, base_url: catalog_base_url(instance_cfg: instance_cfg) }
              )
            rescue Faraday::ConnectionFailed => e
              handle_exception(e, level: :warn, handled: true, operation: 'vertex.runner.discovery.health')
              readiness_failure(error: e)
            rescue StandardError => e
              raise e if discovery_programming_error?(e)

              handle_exception(e, level: :warn, handled: true, operation: 'vertex.runner.discovery.health')
              readiness_failure(error: e)
            end

            # The catalog is static per instance: the provider's STATIC_MODELS
            # list, served as raw model hashes with the entry's :model as the
            # catalog id the pipeline iterates. The pipeline passes
            # instance_cfg as the interface arg; the static catalog does not
            # consume it (Provider#list_models is static too).
            def fetch_raw_models(*)
              Provider::STATIC_MODELS.map { |entry| { **entry, id: entry[:model] } }
            end

            def build_callable(instance_cfg:)
              Legion::Extensions::Llm::Vertex::Helpers::Callable.new(instance_cfg: instance_cfg, logger: log)
            end

            # ── Secondary physical id (dedup/diagnostics only) ────────────────
            # project:location/<8-char credential digest>. Never identity — the
            # instance identity is the operator's config name. Returns nil
            # instead of a fallback when no project or credential is
            # resolvable (discover_instances filters those out; a nil is never
            # claimed under a provider-fallback identity).
            def derive_physical_id(instance_cfg:)
              project = vertex_project(instance_cfg)
              return nil if project.nil? || project.to_s.strip.empty?

              fingerprint = Legion::Extensions::Llm::CredentialSources.credential_fingerprint(
                instance_cfg[:vertex_access_token] || instance_cfg[:vertex_credentials] ||
                  instance_cfg[:access_token] || instance_cfg[:credentials]
              )
              return nil if fingerprint.nil?

              "#{project}:#{vertex_location(instance_cfg)}/#{fingerprint}"
            end

            # ── Offering draft (evidence + metadata; NO weight) ───────────────
            def build_offering_draft(instance_cfg:, instance_key:, model_id:, model_data:)
              model_entry = model_data
              is_embedding = model_entry[:usage_type] == :embedding
              is_gen = model_entry.fetch(:api, :generate_content) == :generate_content

              Legion::Extensions::Llm::Inventory::OfferingDraft.new(
                provider_native_key: model_id,
                model: model_id,
                tier: instance_cfg[:tier] || :cloud,
                operation_evidence: build_operation_evidence(is_embedding: is_embedding, is_generate_content: is_gen),
                capability_evidence: build_capability_evidence(model_entry: model_entry, instance_cfg: instance_cfg),
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

            private

            def vertex_project(instance_cfg)
              instance_cfg[:vertex_project] || instance_cfg[:project]
            end

            def vertex_location(instance_cfg)
              instance_cfg[:vertex_location] || instance_cfg[:location] || 'us-central1'
            end

            # Authoritative operation evidence: an embedding model publishes
            # chat: :unsupported so a plain chat request can never misroute to
            # it; embed is published only for embedding models.
            def build_operation_evidence(is_embedding:, is_generate_content:)
              now = Time.now.freeze
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

            def build_capability_evidence(model_entry:, instance_cfg:)
              now = Time.now.freeze
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
        end
      end
    end
  end
end
