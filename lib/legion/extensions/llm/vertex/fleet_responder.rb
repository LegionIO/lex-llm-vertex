# frozen_string_literal: true

require 'legion/logging'

module Legion
  module Extensions
    module Llm
      module Vertex
        # Optional bridge to the fleet responder helper owned by legion-llm.
        module FleetResponder
          extend Legion::Logging::Helper

          class MissingResponderError < LoadError
          end

          module_function

          def available?
            provider_responder
            true
          rescue LoadError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vertex.fleet_responder.available')
            false
          end

          def enabled_for?(provider_instances)
            provider_responder.enabled_for?(provider_instances)
          rescue LoadError => e
            handle_exception(e, level: :debug, handled: true, operation: 'vertex.fleet_responder.enabled_for')
            false
          end

          def call(**)
            provider_responder.call(**)
          rescue LoadError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vertex.fleet_responder.call')
            raise MissingResponderError,
                  'legion-llm does not expose legion/llm/fleet/provider_responder; install a compatible legion-llm'
          end

          def provider_responder
            return ::Legion::LLM::Fleet::ProviderResponder if defined?(::Legion::LLM::Fleet::ProviderResponder)

            require 'legion/llm/fleet/provider_responder'
            ::Legion::LLM::Fleet::ProviderResponder
          end
        end
      end
    end
  end
end
