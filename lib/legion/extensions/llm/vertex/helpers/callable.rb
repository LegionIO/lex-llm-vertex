# frozen_string_literal: true

require 'faraday'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/vertex/provider'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Helpers
          # Callable wrapper for a Vertex AI provider instance. Delegates the
          # fleet dispatch operations to a per-instance Vertex::Provider (real
          # HTTP dispatch; provider/Faraday errors propagate so
          # normalize_dispatch_error classifies them) and implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          # 0.8.0 callable contract: chat/stream_chat take the rehydrated
          # message array positionally (WorkerExecution dispatch shape) and
          # the Selection-derived model as a bare String; folded wire params
          # become Canonical::Params at this boundary (05 O4).
          class Callable
            # Keys the base Provider exposes as named kwargs for the
            # completion operations. Anything else the fleet passes (sampling
            # scalars, `temperature` — a Canonical::Params member, 05 O4) is
            # folded into Canonical::Params at the dispatch boundary.
            COMPLETION_NAMED_KEYS = %i[tools schema thinking tool_prefs headers].freeze
            # Named kwargs of Vertex's own embed dialect (task_type/title are
            # Vertex wire spellings); anything else folds into params.
            EMBED_NAMED_KEYS = %i[dimensions task_type title headers].freeze

            attr_reader :provider

            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @provider = Provider.new(instance_cfg)
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @provider.disconnect
              @logger.debug { '[vertex][callable] disconnected' }
            end

            # --- Fleet dispatch operations (Fleet::WorkerExecution contract) --

            def chat(messages, model:, **rest)
              # Canonical boundary (N x N law): pipeline dispatch delivers
              # Canonical::Message objects only. Hash/legacy shapes are the
              # bypass class — reject loudly, never coerce.
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.chat(messages, model: model, params: canonical_params(params), **named)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              named, params = split_fleet_kwargs(rest, COMPLETION_NAMED_KEYS)
              provider.stream_chat(messages, model: model, params: canonical_params(params), **named, &)
            end

            def embed(text:, model:, **rest)
              named, params = split_fleet_kwargs(rest, EMBED_NAMED_KEYS)
              provider.embed(text: text, model: model, params: params, **named)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              _named, params = split_fleet_kwargs(rest, [])
              provider.count_tokens(messages: messages, model: model, params: params)
            end

            # --- Error normalization ------------------------------------------

            def normalize_dispatch_error(error:)
              reason = error.message.to_s[0, 512]

              kind = case error
                     when Faraday::ConnectionFailed
                       :connection_failure
                     when Faraday::TimeoutError
                       :timeout
                     when Faraday::ClientError
                       classify_client_error(error: error)
                     when Faraday::ServerError
                       classify_server_error(error: error)
                     when Legion::Extensions::Llm::OverloadedError
                       :overloaded
                     else
                       # ServiceUnavailableError and all other errors map to provider_error.
                       # Never escalate to instance_unavailable from a typed error alone.
                       :provider_error
                     end

              Legion::Extensions::Llm::Routing::ProviderOutcome.new(
                kind: kind,
                reason: reason.empty? ? 'unknown dispatch error' : reason
              )
            end

            private

            # The 0.8.0 completion funnel receives canonical values only
            # (08 F3): the folded wire params become a Canonical::Params at
            # the dispatch boundary — temperature is a params member (05 O4),
            # never a kwarg. A canonical Params already in flight round-trips
            # through from_hash Data-equal (kit T3/T7); unknown keys fold into
            # params metadata (04 L5), never dropped or raised.
            def canonical_params(params)
              Legion::Extensions::Llm::Canonical::Params.from_hash(params)
            end

            # Split the fleet's **rest into the provider's named kwargs and a
            # payload params hash (any passed :params merged with the unknown
            # keys — sampling scalars, temperature, 0.7.x spellings).
            def split_fleet_kwargs(rest, named_keys)
              named = rest.slice(*named_keys)
              extra = rest.reject { |key, _| named.key?(key) }
              params = (extra.delete(:params) || {}).to_h.merge(extra)
              [named, params]
            end

            def classify_client_error(error:)
              case error.response_status
              when 401 then :authentication
              when 403 then :authorization
              when 404 then :model_missing
              when 429 then :rate_limited
              else :invalid_request
              end
            end

            def classify_server_error(error:)
              # NEVER classify raw 503/5xx as instance_unavailable by status alone.
              # Only an explicit flat SERVICE_UNAVAILABLE body signal from Vertex
              # would justify instance_unavailable. Everything else is request-local.
              status = error.response_status
              body = extract_error_body(error: error)

              if status == 503 && body.include?('service_unavailable') && !overload_signal?(body: body)
                :instance_unavailable
              elsif [503, 529].include?(status)
                :overloaded
              else
                :provider_error
              end
            end

            # Faraday::Error#response_body reads the body from either a
            # Hash-shaped or a Faraday::Response/Env-shaped error response, so
            # the body signal survives real adapter-raised errors.
            def extract_error_body(error:)
              error.response_body.to_s.downcase
            end

            def overload_signal?(body:)
              body.include?('overload') || body.include?('model not ready') || body.include?('model_not_ready')
            end
          end
        end
      end
    end
  end
end
