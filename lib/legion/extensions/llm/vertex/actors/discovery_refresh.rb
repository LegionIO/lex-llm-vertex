# frozen_string_literal: true

require 'digest'

begin
  require 'legion/extensions/actors/every'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

begin
  require 'legion/extensions/llm/inventory/scoped_refresher'
rescue LoadError => e
  warn(e.message) if $VERBOSE
end

return unless defined?(Legion::Extensions::Actors::Every)

module Legion
  module Extensions
    module Llm
      module Vertex
        module Actor
          class DiscoveryRefresh < Legion::Extensions::Actors::Every # rubocop:disable Style/Documentation
            include Legion::Logging::Helper

            if defined?(Legion::Extensions::Llm::Inventory::ScopedRefresher)
              include Legion::Extensions::Llm::Inventory::ScopedRefresher
            end

            REFRESH_INTERVAL = 1800

            def self.every_seconds = 3600

            def runner_class    = self.class
            def runner_function = 'manual'
            def run_now?        = true
            def use_runner?     = false
            def check_subtask?  = false
            def generate_task?  = false

            def time
              return REFRESH_INTERVAL unless defined?(Legion::Settings)

              Legion::Settings.dig(:extensions, :llm, :vertex, :discovery_interval) || REFRESH_INTERVAL
            end

            def scope_key
              { provider: :vertex }
            end

            def compute_lanes_for_scope(**)
              return [] unless defined?(Legion::LLM::Call::Registry)

              settings      = Legion::Settings.dig(:extensions, :llm, :vertex) || {}
              fleet_enabled = settings.dig(:fleet, :dispatch, :enabled)
              instances     = Legion::LLM::Call::Registry.all_instances.select do |e|
                (e[:provider] || '').to_sym == :vertex
              end

              instances.flat_map do |entry|
                lanes_for_instance(entry, fleet_enabled: fleet_enabled)
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vertex.actor.compute_lanes_for_scope')
              []
            end

            private

            def lanes_for_instance(entry, fleet_enabled: false)
              adapter     = entry[:adapter]
              instance_id = entry[:instance]
              lanes       = []
              Array(adapter.discover_offerings(live: false)).each do |offering|
                lane = build_lane(offering, instance_id)
                lanes << lane
                lanes << fleet_lane(lane, instance_id, offering) if fleet_enabled && lane[:type] == :inference
              end
              lanes
            end

            def build_lane(offering, instance_id)
              type  = offering_type(offering)
              tier  = offering[:tier]&.to_sym || :cloud
              caps  = normalize_capabilities(offering[:capabilities])
              flds  = { tier: tier, provider_family: :vertex, instance_id: instance_id,
                        type: type, model: offering[:model] }
              {
                id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(flds),
                tier: tier,
                provider_family: :vertex,
                instance_id: instance_id,
                model: offering[:model],
                canonical_model_alias: offering[:canonical_model_alias],
                type: type,
                capabilities: caps,
                limits: offering[:limits] || {},
                enabled: offering.fetch(:enabled, true),
                cost: offering[:cost] || {}
              }
            end

            def fleet_lane(lane, instance_id, offering)
              flds = { tier: :fleet, provider_family: :vertex, instance_id: instance_id,
                       type: lane[:type], model: offering[:model] }
              lane.merge(id: Legion::Extensions::Llm::Inventory::ScopedRefresher.compose_id(flds), tier: :fleet)
            end

            def offering_type(offering)
              %i[embed embedding].include?(offering[:type]&.to_sym) ? :embedding : :inference
            end

            def normalize_capabilities(caps)
              return [] unless defined?(Legion::Extensions::Llm::Inventory::Capabilities) &&
                               Legion::Extensions::Llm::Inventory::Capabilities.respond_to?(:normalize)

              Legion::Extensions::Llm::Inventory::Capabilities.normalize(caps)
            end

            public

            def credential_hash(**)
              settings = Legion::Settings.dig(:extensions, :llm, :vertex) || {}
              ::Digest::SHA256.hexdigest(settings[:api_key].to_s + settings[:instances].to_s)[0, 16]
            end

            def manual
              log.debug('[vertex][discovery_refresh] refreshing model list')
              tick if respond_to?(:tick)
              return unless defined?(Legion::LLM::Discovery)

              Legion::LLM::Discovery.refresh_discovered_models!(provider: :vertex)

              if defined?(Legion::LLM::Router) && Legion::LLM::Router.respond_to?(:populate_auto_rules)
                Legion::LLM::Router.populate_auto_rules(Legion::LLM::Discovery.discovered_instances)
              end
              if defined?(Legion::LLM::Inventory) && Legion::LLM::Inventory.respond_to?(:invalidate_offerings_cache!)
                Legion::LLM::Inventory.invalidate_offerings_cache!
              end
            rescue StandardError => e
              handle_exception(e, level: :warn, handled: true, operation: 'vertex.actor.discovery_refresh')
            end
          end
        end
      end
    end
  end
end
