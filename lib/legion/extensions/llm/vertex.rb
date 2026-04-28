# frozen_string_literal: true

require 'legion/extensions/llm'
require 'legion/extensions/llm/vertex/provider'
require 'legion/extensions/llm/vertex/version'

module Legion
  module Extensions
    module Llm
      # Google Cloud Vertex AI provider extension namespace.
      module Vertex
        extend ::Legion::Extensions::Core if ::Legion::Extensions.const_defined?(:Core, false)

        PROVIDER_FAMILY = :vertex

        def self.default_settings
          ::Legion::Extensions::Llm.provider_settings(
            family: PROVIDER_FAMILY,
            discovery: { enabled: true, live: false, locations: %w[us-central1 us-east5 europe-west4] },
            instance: {
              endpoint: 'https://us-central1-aiplatform.googleapis.com/v1',
              project: 'env://GOOGLE_CLOUD_PROJECT',
              location: 'us-central1',
              tier: :frontier,
              transport: :http,
              credentials: {
                provider: 'google-application-default-credentials',
                access_token: 'env://VERTEX_ACCESS_TOKEN',
                credentials_file: 'env://GOOGLE_APPLICATION_CREDENTIALS'
              },
              usage: { inference: true, embedding: true, token_counting: true },
              limits: { concurrency: 4 }
            }
          )
        end

        def self.provider_class
          Provider
        end
      end
    end
  end
end

Legion::Extensions::Llm::Provider.register(Legion::Extensions::Llm::Vertex::PROVIDER_FAMILY,
                                           Legion::Extensions::Llm::Vertex::Provider)
