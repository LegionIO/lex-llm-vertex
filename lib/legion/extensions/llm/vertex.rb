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
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            instance: {
              endpoint: nil,
              tier: :frontier,
              transport: :http,
              credentials: {
                access_token: nil,
                credentials: nil
              },
              provider: {
                project: nil,
                location: Provider::DEFAULT_LOCATION,
                model_aliases: {}
              },
              usage: { inference: true, embedding: true, image: false },
              limits: { concurrency: 4 },
              fleet: {
                enabled: false,
                respond_to_requests: false,
                capabilities: %i[chat stream_chat embed],
                lanes: [],
                concurrency: 4,
                queue_suffix: nil
              }
            }
          )
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

          instances[:settings] = normalize_instance_config(cfg).merge(tier: :cloud)
        end

        def self.discover_named_instances(instances)
          cfg = CredentialSources.setting(:extensions, :llm, :vertex)
          return unless cfg.is_a?(Hash)

          named = cfg[:instances] || cfg['instances']
          return unless named.is_a?(Hash)

          named.each do |name, config|
            next unless config.is_a?(Hash) && vertex_credentials_present?(config)

            instances[name.to_sym] = normalize_instance_config(config).merge(tier: :cloud)
          end
        end

        def self.vertex_credentials_present?(cfg)
          project = cfg[:project] || cfg['project']
          return false if project.nil? || project.to_s.strip.empty?

          token = cfg[:access_token] || cfg['access_token']
          creds = cfg[:credentials] || cfg['credentials']
          !(token.nil? && creds.nil?)
        end

        def self.normalize_instance_config(config)
          normalized = config.to_h.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
          normalized[:vertex_project] ||= normalized.delete(:project)
          normalized[:vertex_location] ||= normalized.delete(:location)
          normalized[:vertex_api_base] ||= normalized.delete(:base_url)
          normalized[:vertex_api_base] ||= normalized.delete(:api_base)
          normalized[:vertex_api_base] ||= normalized.delete(:endpoint)
          normalized[:vertex_access_token] ||= normalized.delete(:access_token)
          normalized[:vertex_credentials] ||= normalized.delete(:credentials)
          normalized[:vertex_model_aliases] ||= normalized.delete(:model_aliases)
          normalized.compact.except(:instances)
        end

        private_class_method :discover_default_instance, :discover_named_instances, :vertex_credentials_present?,
                             :normalize_instance_config

        Legion::Extensions::Llm::Configuration.register_provider_options(Provider.configuration_options) if
          Legion::Extensions::Llm::Configuration.respond_to?(:register_provider_options)
      end
    end
  end
end
