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
        extend Legion::Extensions::Llm::AutoRegistration

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

        def self.discover_instances
          instances = {}
          discover_default_instance(instances)
          discover_named_instances(instances)
          instances
        end

        def self.discover_default_instance(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :vertex)
          return unless cfg.is_a?(Hash) && vertex_credentials_present?(cfg)

          instances[:settings] = cfg.except(:instances, 'instances').merge(tier: :cloud)
        end

        def self.discover_named_instances(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :vertex)
          return unless cfg.is_a?(Hash)

          named = cfg[:instances] || cfg['instances']
          return unless named.is_a?(Hash)

          named.each do |name, config|
            next unless config.is_a?(Hash) && vertex_credentials_present?(config)

            instances[name.to_sym] = config.merge(tier: :cloud)
          end
        end

        def self.vertex_credentials_present?(cfg)
          project = cfg[:project] || cfg['project']
          return false if project.nil? || project.to_s.strip.empty?

          token = cfg[:access_token] || cfg['access_token']
          creds = cfg[:credentials] || cfg['credentials']
          !(token.nil? && creds.nil?)
        end

        private_class_method :discover_default_instance, :discover_named_instances, :vertex_credentials_present?
      end
    end
  end
end

Legion::Extensions::Llm::Configuration.register_provider_options(
  Legion::Extensions::Llm::Vertex::Provider.configuration_options
)

Legion::Extensions::Llm::Vertex.register_discovered_instances
