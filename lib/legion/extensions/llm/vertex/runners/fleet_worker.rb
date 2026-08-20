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
          # protocol-v3 envelope plus AMQP metadata; the whole message is the
          # payload for the shared responder (which selects the envelope
          # fields it needs).
          module FleetWorker
            module_function

            def handle_fleet_request(**message)
              # Protocol v3 (06): exact-only execution against the SSOT
              # registry — the responder never constructs a provider; the
              # callable is the captured registry handle.
              Legion::Extensions::Llm::Fleet::ProviderResponder.call(
                payload: message,
                provider_family: Vertex::PROVIDER_FAMILY,
                registry: Legion::Extensions::Llm::Inventory::Registry
              )
            end
          end
        end
      end
    end
  end
end
