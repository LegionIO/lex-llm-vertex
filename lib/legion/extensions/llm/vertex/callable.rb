# frozen_string_literal: true

require 'faraday'
require 'legion/extensions/llm/routing/provider_outcome'
require 'legion/extensions/llm/vertex/provider'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Actor
          # Callable wrapper for a Vertex AI provider instance. Delegates the
          # fleet dispatch operations to a per-instance Vertex::Provider (real
          # HTTP dispatch; provider/Faraday errors propagate so
          # normalize_dispatch_error classifies them) and implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class VertexCallable
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
              provider.chat(messages, model: model, **rest)
            end

            def stream_chat(messages, model:, **rest, &)
              provider.enforce_canonical_messages!(messages)
              provider.stream_chat(messages, model: model, **rest, &)
            end

            def embed(text:, model:, **rest)
              provider.embed(text: text, model: model, **rest)
            end

            def count_tokens(messages:, model:, **rest)
              provider.enforce_canonical_messages!(messages)
              provider.count_tokens(messages: messages, model: model, **rest)
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
