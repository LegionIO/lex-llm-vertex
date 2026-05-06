# frozen_string_literal: true

require 'legion/extensions/llm/fleet/provider_responder'
require 'legion/extensions/llm/vertex/provider'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Runners
          # Runner entrypoint for Vertex fleet request execution.
          module FleetWorker
            module_function

            def handle_fleet_request(payload, delivery: nil, properties: nil)
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: payload,
                provider_family: Vertex::PROVIDER_FAMILY,
                provider_class: Vertex::Provider,
                provider_instances: -> { Vertex.discover_instances },
                delivery: delivery,
                properties: properties
              )
            end
          end
        end
      end
    end
  end
end
