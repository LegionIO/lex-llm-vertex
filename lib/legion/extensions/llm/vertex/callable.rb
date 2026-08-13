# frozen_string_literal: true

require 'legion/extensions/llm/routing/provider_outcome'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Actor
          # Callable wrapper for a Vertex AI provider instance. Implements the
          # `disconnect` and `normalize_dispatch_error(error:)` contracts
          # required by Inventory::CallableHandle and Routing::ProviderOutcome.
          class VertexCallable
            def initialize(instance_cfg:, logger:)
              @instance_cfg = instance_cfg
              @logger = logger
              @disconnected = false
            end

            def disconnected?
              @disconnected
            end

            def disconnect
              @disconnected = true
              @logger.debug { '[vertex][callable] disconnected' }
            end

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
              status = error.respond_to?(:response_status) ? error.response_status : nil
              case status
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
              status = error.respond_to?(:response_status) ? error.response_status : nil
              body = extract_error_body(error: error)

              if status == 503 && body.include?('service_unavailable') && !overload_signal?(body: body)
                :instance_unavailable
              elsif [503, 529].include?(status)
                :overloaded
              else
                :provider_error
              end
            end

            def extract_error_body(error:)
              return '' unless error.respond_to?(:response) && error.response.is_a?(Hash)

              error.response[:body].to_s.downcase
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
