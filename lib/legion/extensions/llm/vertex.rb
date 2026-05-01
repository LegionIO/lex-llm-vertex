# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vertex/provider'
require 'legion/extensions/llm/vertex/version'

module Legion
  module Extensions
    module Llm
      # Google Cloud Vertex AI provider extension namespace.
      module Vertex
        extend Legion::Logging::Helper
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :vertex

        def self.default_settings
          {
            enabled: false,
            default_model: nil,
            project: nil,
            location: 'us-central1',
            model_whitelist: [],
            model_blacklist: [],
            model_cache_ttl: 3600,
            tls: { enabled: false, verify: :peer },
            instances: {}
          }
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Configuration.register_provider_options(
  Legion::Extensions::Llm::Vertex::Provider.configuration_options
)
