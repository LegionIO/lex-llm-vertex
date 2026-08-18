# frozen_string_literal: true

begin
  require 'legion/extensions/actors/subscription'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

unless defined?(Legion::Extensions::Actors::Subscription)
  raise LoadError, 'LegionIO actor runtime is required for Vertex fleet worker'
end

require 'legion/extensions/llm/vertex'
require 'legion/extensions/llm/vertex/runners/fleet_worker'
require 'legion/extensions/llm/fleet/provider_responder'

module Legion
  module Extensions
    module Llm
      module Vertex
        module Actor
          # Subscription actor for Vertex fleet request consumption.
          #
          # runner_class MUST be the constant (not a String): the Subscription
          # dispatch path calls runner_class.send(runner_function, **message)
          # directly when use_runner? is false, and a String cannot be send-ed.
          # The runner entrypoint is kwargs-only to match that call.
          class FleetWorker < Legion::Extensions::Actors::Subscription
            def runner_class
              Legion::Extensions::Llm::Vertex::Runners::FleetWorker
            end

            def runner_function
              'handle_fleet_request'
            end

            def use_runner?
              false
            end

            def enabled?
              Legion::Extensions::Llm::Fleet::ProviderResponder.enabled_for?(Vertex.discover_instances)
            end
          end
        end
      end
    end
  end
end
