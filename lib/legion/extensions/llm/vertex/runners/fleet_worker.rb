# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/vertex'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Runners
          # Runner entrypoint for Vertex fleet request execution.
          #
          # The Subscription dispatch path invokes this as
          # handle_fleet_request(**message) where message is the decoded
          # protocol-v2 envelope plus AMQP metadata; the whole message is the
          # payload for the shared responder (which selects the envelope
          # fields it needs).
          module FleetWorker
            module_function

            def handle_fleet_request(**message)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: message,
                provider_family: Vertex::PROVIDER_FAMILY,
                provider_class: Vertex::Provider,
                provider_instances: -> { Vertex.discover_instances }
              )
            end
          end
        end
      end
    end
  end
end
