# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/extensions/llm'
require 'securerandom'

module Legion
  module Extensions
    module Llm
      module Vertex
        # Google Cloud Vertex AI provider implementation for the Legion::Extensions::Llm contract.
        class Provider < Legion::Extensions::Llm::Provider
          STATIC_MODELS = [
            { model: 'gemini-2.5-flash', alias: 'gemini-flash', publisher: 'google', model_family: :gemini },
            { model: 'gemini-2.5-pro', alias: 'gemini-pro', publisher: 'google', model_family: :gemini },
            { model: 'gemini-embedding-001', alias: 'gemini-embedding', publisher: 'google',
              model_family: :gemini, usage_type: :embedding },
            { model: 'text-embedding-005', alias: 'text-embedding', publisher: 'google',
              model_family: :gemini, usage_type: :embedding },
            { model: 'claude-sonnet-4-5', alias: 'claude-sonnet', publisher: 'anthropic',
              model_family: :anthropic, api: :raw_predict },
            { model: 'mistral-medium-3', alias: 'mistral-medium', publisher: 'mistralai',
              model_family: :mistral, api: :raw_predict },
            { model: 'llama-4-maverick', alias: 'llama-4-maverick', publisher: 'meta',
              model_family: :meta, api: :raw_predict }
          ].freeze

          ALIASES = STATIC_MODELS.to_h { |entry| [entry.fetch(:alias), entry.fetch(:model)] }.freeze
          PUBLISHERS = STATIC_MODELS.to_h { |entry| [entry.fetch(:model), entry.fetch(:publisher)] }.freeze
          API_MODES = STATIC_MODELS.to_h { |entry| [entry.fetch(:model), entry.fetch(:api, :generate_content)] }.freeze
          MODEL_FAMILIES = STATIC_MODELS.to_h { |entry| [entry.fetch(:model), entry.fetch(:model_family)] }.freeze

          class << self
            def slug = 'vertex'
            def default_transport = :http
            def default_tier = :cloud

            def configuration_options
              %i[
                vertex_project
                vertex_location
                vertex_api_base
                vertex_access_token
                vertex_credentials
                vertex_model_aliases
                vertex_discovery_live
              ]
            end

            def configuration_requirements = []
            def capabilities = Capabilities

            def resolve_model_id(model_id, config: nil)
              configured_aliases = config&.vertex_model_aliases
              aliases = ALIASES.merge((configured_aliases || {}).transform_keys(&:to_s))
              aliases.fetch(model_id.to_s, model_id.to_s)
            end
          end

          # Capability predicates inferred from Vertex publisher model IDs and API modality.
          module Capabilities
            module_function

            def chat?(model) = !embeddings?(model)
            def streaming?(model) = chat?(model)
            def vision?(model) = model_id(model).match?(/gemini|claude|mistral|llama/)
            def functions?(model) = chat?(model)
            def embeddings?(model) = model_id(model).match?(/embedding|embed/)

            def model_id(model)
              return model.fetch('model', model.fetch('id', '')) if model.is_a?(Hash)

              model.respond_to?(:id) ? model.id.to_s : model.to_s
            end
          end

          def api_base
            config.vertex_api_base || "https://#{location}-aiplatform.googleapis.com/v1"
          end

          def headers
            identity_headers.merge({ 'Authorization' => bearer_token,
                                     'Content-Type' => 'application/json; charset=utf-8' }.compact)
          end

          def project = config.vertex_project || ENV.fetch('GOOGLE_CLOUD_PROJECT', nil)
          def location = config.vertex_location
          def default_publisher = 'google'
          def models_url = publisher_parent

          def completion_url(model: @model)
            raise ArgumentError, 'model is required for completion_url' unless model

            generate_content_url(model: model)
          end

          def stream_url(model: @model)
            raise ArgumentError, 'model is required for stream_url' unless model

            stream_generate_content_url(model: model)
          end

          def count_tokens_url(model:) = "#{publisher_model_path(model)}:countTokens"
          def embedding_url(model:) = "#{publisher_model_path(model)}:predict"

          def generate_content_url(model:)
            "#{publisher_model_path(model)}:generateContent"
          end

          def stream_generate_content_url(model:)
            "#{publisher_model_path(model)}:streamGenerateContent?alt=sse"
          end

          def raw_predict_url(model:, stream: false)
            suffix = stream ? 'streamRawPredict' : 'rawPredict'
            "#{publisher_model_path(model)}:#{suffix}"
          end

          def list_models(**_filters)
            log.info { 'listing available Vertex models from static catalog' }
            STATIC_MODELS.map { |entry| model_info_from_static(entry) }.tap do |models|
              log.info { "listed #{models.size} Vertex model(s)" }
            end
          end

          def discover_offerings(live: false, **filters)
            unless live
              return static_offerings(**filters).select do |offering|
                model_allowed?(short_model_id(offering.model))
              end
            end

            super
          end

          def offering_for(model:, model_family: nil, instance_id: nil, **metadata)
            model_id = model_id(model)
            publisher = metadata.delete(:publisher) || publisher_for(model_id)
            family = model_family || metadata.delete(:model_family) || model_family_for(model_id, publisher)

            build_offering(
              model: resource_name(model_id, publisher:),
              alias_name: alias_for(model_id),
              model_family: family,
              instance_id: instance_id || provider_instance_id,
              publisher: publisher,
              usage_type: metadata.delete(:usage_type) || usage_type_for(model_id),
              api: metadata.delete(:api) || api_for(model_id),
              metadata: metadata
            )
          end

          def health(live: false)
            log.info { "checking health live=#{live} project=#{project} location=#{location}" }
            baseline = {
              provider: :vertex,
              project: project,
              location: location,
              configured: configured?,
              ready: configured?,
              live: live,
              credentials: credential_source
            }
            return baseline.merge(checked: false) unless live

            connection.get(models_url)
            baseline.merge(checked: true)
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vertex.provider.health')
            baseline.merge(checked: true, ready: false, error: e.class.name, message: e.message)
          end

          def readiness(live: false)
            health(live:).merge(local: false, remote: true, api_base: api_base,
                                endpoints: endpoint_manifest)
          end

          def chat(
            messages:,
            model:,
            temperature: nil,
            max_tokens: nil,
            tools: {},
            tool_prefs: nil,
            params: {},
            **_provider_options
          )
            model_id = model_id(model)
            log.info { "chat model=#{model_id} messages=#{messages.size}" }
            @model = model_id
            payload = Utils.deep_merge(chat_payload(messages, model: model_id, temperature:, max_tokens:, tools:,
                                                              tool_prefs:, stream: false), params)
            response = connection.post(chat_url(model_id, stream: false), payload)
            parse_chat_response(response, model: model_id)
          end

          def stream(messages:, model:, temperature: nil, max_tokens: nil, tools: {}, tool_prefs: nil, params: {},
                     **_provider_options)
            model_id = model_id(model)
            log.info { "stream model=#{model_id} messages=#{messages.size}" }
            @model = model_id
            payload = Utils.deep_merge(chat_payload(messages, model: model_id, temperature:, max_tokens:, tools:,
                                                              tool_prefs:, stream: true), params)
            response = connection.post(chat_url(model_id, stream: true), payload)
            chunk = build_chunk(response.body, model: model_id)
            yield chunk if block_given? && chunk.content
            parse_chat_response(response, model: model_id)
          end

          def stream_chat(messages:, model:, tools: {}, temperature: nil, max_tokens: nil, params: {}, tool_prefs: nil,
                          **provider_options, &)
            stream(messages:, model:, temperature:, max_tokens:, tools:, tool_prefs:, params:, **provider_options, &)
          end

          def count_tokens(
            messages:,
            model:,
            params: {}
          )
            model_id = model_id(model)
            log.info { "count_tokens model=#{model_id}" }
            unless generate_content_model?(model_id)
              return {
                supported: false,
                provider: :vertex,
                model: resource_name(model_id),
                reason: 'Vertex countTokens is standardized for generateContent publisher models'
              }
            end

            payload = Utils.deep_merge({ contents: format_messages(messages) }, params)
            response = connection.post(count_tokens_url(model: model_id), payload)
            { input_tokens: response.body['totalTokens'], raw: response.body }
          end

          def embed(
            text:,
            model:,
            dimensions: nil,
            task_type: nil,
            title: nil,
            params: {},
            **_provider_options
          )
            model_id = model_id(model)
            log.info { "embed model=#{model_id} inputs=#{Array(text).size}" }
            unless Capabilities.embeddings?(model_id)
              raise NotImplementedError, "Vertex embedding payload for #{model_id} is not standardized"
            end

            instances = Array(text).map { |item| embedding_instance(item, task_type:, title:) }
            parameters = { outputDimensionality: dimensions }.compact
            payload = Utils.deep_merge({ instances: instances, parameters: parameters }, params)
            response = connection.post(embedding_url(model: model_id), payload)
            parse_embedding_response(response, model: model_id)
          end

          def complete(messages, tools:, temperature:, model:, params: {}, _headers: {}, schema: nil, thinking: nil,
                       tool_prefs: nil, &)
            payload = params.dup
            payload[:generationConfig] = Utils.deep_merge(payload[:generationConfig] || {},
                                                          generation_config(temperature, schema, thinking))
            if block_given?
              stream(messages:, model:, temperature:, tools:, tool_prefs:, params: payload, &)
            else
              chat(messages:, model:, temperature:, tools:, tool_prefs:, params: payload)
            end
          end

          private

          def model_info_from_static(entry)
            caps = default_capabilities(entry[:model], api: entry.fetch(:api, :generate_content))
            Legion::Extensions::Llm::Model::Info.new(
              id: entry[:model],
              name: entry[:alias] || entry[:model],
              provider: :vertex,
              family: entry[:model_family].to_s,
              capabilities: caps.map(&:to_s),
              metadata: {
                publisher: entry[:publisher],
                project: project,
                location: location,
                api: entry.fetch(:api, :generate_content)
              }.compact
            )
          end

          def model_info_from_offering(offering)
            Legion::Extensions::Llm::Model::Info.new(
              id: offering.model,
              name: offering.metadata[:alias] || offering.model,
              provider: :vertex,
              family: offering.metadata[:model_family].to_s,
              capabilities: offering.capabilities.map(&:to_s),
              metadata: offering.metadata
            )
          end

          def static_offerings(**filters)
            STATIC_MODELS.filter_map do |entry|
              next if filters[:model_family] && entry.fetch(:model_family) != filters[:model_family].to_sym
              next if filters[:publisher] && entry.fetch(:publisher) != filters[:publisher].to_s

              offering_for(**entry.slice(:model, :model_family, :publisher, :usage_type, :api))
            end
          end

          def offering_from_live_model(model)
            name = model['name'] || model['publisherModelName'] || model['model'] || model['id']
            publisher = publisher_from_resource(name) || model['publisher'] || default_publisher
            id = name.to_s.split('/').last
            offering_for(model: id, publisher:, metadata: model)
          end

          def offering_from_model(model_info, health: {})
            metadata = model_info.respond_to?(:metadata) ? model_info.metadata.to_h : {}
            raw_model = model_info.respond_to?(:id) ? model_info.id : model_info
            publisher = metadata[:publisher] || metadata['publisher'] || publisher_for(raw_model)
            api = metadata[:api] || metadata['api'] || api_for(raw_model)
            alias_name = model_info.respond_to?(:name) ? model_info.name : nil
            alias_name = nil if alias_name.to_s.empty? || alias_name.to_s == raw_model.to_s

            build_offering(
              model: resource_name(raw_model, publisher: publisher),
              alias_name: alias_name,
              model_family: if model_info.respond_to?(:family) && model_info.family
                              model_info.family.to_sym
                            else
                              model_family_for(
                                raw_model, publisher
                              )
                            end,
              instance_id: if model_info.respond_to?(:instance)
                             model_info.instance || provider_instance_id
                           else
                             provider_instance_id
                           end,
              publisher: publisher,
              usage_type: if model_info.respond_to?(:embedding?) && model_info.embedding?
                            :embedding
                          else
                            usage_type_for(raw_model)
                          end,
              api: api,
              health: health,
              metadata: metadata.merge(
                limits: {
                  context_window: model_info.respond_to?(:context_length) ? model_info.context_length : nil,
                  max_output_tokens: model_info.respond_to?(:max_output_tokens) ? model_info.max_output_tokens : nil
                }.compact
              )
            )
          end

          def build_offering(model:, model_family:, usage_type:, publisher:, api:, instance_id: nil,
                             alias_name: nil, health: {}, metadata: {})
            resolved_instance_id = instance_id || provider_instance_id
            policy = resolve_capability_policy(model, api:, metadata:, instance_id: resolved_instance_id)

            Legion::Extensions::Llm::Routing::ModelOffering.new(
              provider_family: :vertex,
              instance_id: resolved_instance_id,
              transport: offering_transport,
              tier: offering_tier,
              model: model,
              usage_type: usage_type,
              capabilities: base_capabilities(model, api:) + policy[:capabilities],
              capability_sources: policy[:sources],
              limits: metadata.delete(:limits) || {},
              health: health,
              metadata: metadata.merge(
                model_family: model_family,
                alias: alias_name,
                publisher: publisher,
                project: project,
                location: location,
                api: api
              ).compact
            )
          end

          def publisher_parent
            "projects/#{project}/locations/#{location}/publishers/#{default_publisher}/models"
          end

          def publisher_model_path(model)
            id = model_id(model)
            return id.delete_prefix("#{api_base}/") if id.start_with?('projects/')

            "projects/#{project}/locations/#{location}/publishers/#{publisher_for(id)}/models/#{id}"
          end

          def resource_name(model, publisher: nil)
            id = model_id(model)
            return id if id.start_with?('projects/')

            "projects/#{project}/locations/#{location}/publishers/#{publisher || publisher_for(id)}/models/#{id}"
          end

          def chat_url(model, stream:)
            return raw_predict_url(model:, stream:) unless generate_content_model?(model)

            stream ? stream_generate_content_url(model:) : generate_content_url(model:)
          end

          def chat_payload(messages, model:, temperature:, max_tokens:, tools:, tool_prefs:, stream:)
            if generate_content_model?(model)
              generate_content_payload(messages, temperature:, max_tokens:, tools:, tool_prefs:)
            else
              raw_predict_payload(messages, model:, temperature:, max_tokens:, stream:)
            end
          end

          def generate_content_payload(messages, temperature:, max_tokens:, tools:, tool_prefs:)
            {
              contents: format_messages(messages.reject { |message| message.role == :system }),
              systemInstruction: system_instruction(messages),
              generationConfig: generation_config(temperature, nil, nil, max_tokens:),
              tools: format_tools(tools),
              toolConfig: tool_config(tool_prefs)
            }.compact
          end

          def raw_predict_payload(messages, model:, temperature:, max_tokens:, stream:)
            {
              model: model,
              messages: messages.reject { |message| message.role == :system }.map do |message|
                { role: raw_role(message.role), content: content_text(message.content) }
              end,
              temperature: temperature,
              max_tokens: max_tokens,
              stream: stream
            }.compact
          end

          def generation_config(temperature, schema, thinking, max_tokens: nil)
            {
              temperature: temperature,
              maxOutputTokens: max_tokens,
              responseMimeType: ('application/json' if schema),
              responseSchema: schema_hash(schema),
              thinkingConfig: thinking_config(thinking)
            }.compact
          end

          def schema_hash(schema)
            return unless schema

            schema.respond_to?(:to_h) ? schema.to_h.fetch(:schema, schema.to_h) : schema
          end

          def thinking_config(thinking)
            return nil unless thinking

            budget = thinking.respond_to?(:budget) ? thinking.budget : nil
            budget ||= thinking[:budget] || thinking['budget'] if thinking.is_a?(Hash)
            { thinkingBudget: budget }.compact
          end

          def system_instruction(messages)
            parts = messages.select { |message| message.role == :system }
                            .flat_map { |message| content_parts(message.content) }
            return nil if parts.empty?

            { parts: parts }
          end

          def format_messages(messages)
            messages.map { |message| { role: vertex_role(message.role), parts: message_parts(message) } }
          end

          def vertex_role(role)
            role == :assistant ? 'model' : 'user'
          end

          def raw_role(role)
            role == :assistant ? 'assistant' : 'user'
          end

          def message_parts(message)
            return tool_call_parts(message) if message.tool_call?
            return tool_result_parts(message) if message.tool_result?

            content_parts(message.content)
          end

          def content_parts(content)
            return Array(content.value) if content.is_a?(Legion::Extensions::Llm::Content::Raw)
            return [{ text: Legion::JSON.generate(content) }] if content.is_a?(Hash) || content.is_a?(Array)
            return [{ text: content.to_s }] unless content.is_a?(Legion::Extensions::Llm::Content)

            parts = []
            parts << { text: content.text } if content.text
            content.attachments.each { |attachment| parts << attachment_part(attachment) }
            parts
          end

          def attachment_part(attachment)
            if attachment.text?
              { text: attachment.for_llm }
            else
              { inlineData: { mimeType: attachment.mime_type, data: attachment.encoded } }
            end
          end

          def content_text(content)
            return content.text if content.respond_to?(:text)

            content.to_s
          end

          def tool_call_parts(message)
            # Array is canonical (name-keyed hashes dropped parallel same-name calls)
            calls = message.tool_calls.is_a?(Hash) ? message.tool_calls.values : Array(message.tool_calls)
            calls.map do |tool_call|
              { functionCall: { name: tool_call.name, args: tool_call.arguments } }
            end
          end

          def tool_result_parts(message)
            [{
              functionResponse: {
                name: message.tool_call_id,
                response: { name: message.tool_call_id, content: content_parts(message.content) }
              }
            }]
          end

          def format_tools(tools)
            return nil if tools.empty?

            [{
              functionDeclarations: tools.values.map do |tool|
                {
                  name: Legion::Extensions::Llm::Canonical::ToolSchema.tool_name(tool),
                  description: Legion::Extensions::Llm::Canonical::ToolSchema.tool_description(tool),
                  parameters: Legion::Extensions::Llm::Canonical::ToolSchema.extract(tool)
                }
              end
            }]
          end

          def tool_config(tool_prefs)
            return nil unless tool_prefs

            choice = tool_prefs[:choice] || tool_prefs['choice']
            return nil unless choice

            { functionCallingConfig: { mode: choice.to_s } }
          end

          def parse_chat_response(response, model:)
            body = response.body
            if generate_content_model?(model)
              parse_generate_content_response(body, model:)
            else
              parse_raw_predict_response(body, model:)
            end
          end

          def parse_generate_content_response(body, model:)
            parts = response_parts(body)
            usage = body['usageMetadata'] || {}

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: text_content(parts),
              tool_calls: parse_tool_calls(parts),
              input_tokens: usage['promptTokenCount'],
              output_tokens: output_tokens(usage),
              cached_tokens: usage['cachedContentTokenCount'],
              thinking_tokens: usage['thoughtsTokenCount'],
              model_id: body['modelVersion'] || model,
              raw: body
            )
          end

          def parse_raw_predict_response(body, model:)
            choice = Array(body['choices']).first || {}
            message = choice['message'] || {}
            usage = body['usage'] || {}

            Legion::Extensions::Llm::Message.new(
              role: :assistant,
              content: message['content'] || choice['text'],
              input_tokens: usage['prompt_tokens'],
              output_tokens: usage['completion_tokens'],
              model_id: body['model'] || model,
              raw: body
            )
          end

          def build_chunk(body, model:)
            parts = response_parts(body)
            return raw_chunk(body, model:) if parts.empty?

            usage = body['usageMetadata'] || {}
            Legion::Extensions::Llm::Chunk.new(
              role: :assistant,
              content: text_content(parts),
              tool_calls: parse_tool_calls(parts),
              input_tokens: usage['promptTokenCount'],
              output_tokens: output_tokens(usage),
              model_id: body['modelVersion'] || model,
              raw: body
            )
          end

          def raw_chunk(body, model:)
            delta = Array(body['choices']).first&.dig('delta') || Array(body['choices']).first&.dig('message') || {}
            Legion::Extensions::Llm::Chunk.new(role: :assistant, content: delta['content'],
                                               model_id: body['model'] || model, raw: body)
          end

          def response_parts(body)
            body.dig('candidates', 0, 'content', 'parts') || []
          end

          def text_content(parts)
            text = parts.reject { |part| part['thought'] }.filter_map { |part| part['text'] }.join
            text.empty? ? nil : text
          end

          def output_tokens(usage)
            candidates = usage['candidatesTokenCount'] || 0
            thoughts = usage['thoughtsTokenCount'] || 0
            total = candidates + thoughts
            total.positive? ? total : nil
          end

          def parse_tool_calls(parts)
            calls = parts.each_with_object({}) do |part, result|
              function_call = part['functionCall']
              next unless function_call

              id = SecureRandom.uuid
              result[id] = Legion::Extensions::Llm::ToolCall.new(
                id: id,
                name: function_call['name'],
                arguments: function_call['args'] || {}
              )
            end
            calls.empty? ? nil : calls
          end

          def parse_embedding_response(response, model:)
            predictions = response.body['predictions'] || []
            vectors = predictions.map do |prediction|
              prediction['embeddings']&.fetch('values', nil) || prediction['values']
            end
            vectors = vectors.first if vectors.length == 1
            statistics = predictions.first&.dig('embeddings', 'statistics') || {}
            Legion::Extensions::Llm::Embedding.new(vectors: vectors, model: model,
                                                   input_tokens: statistics['token_count'] || 0)
          end

          def embedding_instance(text, task_type:, title:)
            { content: text, task_type: task_type, title: title }.compact
          end

          def default_capabilities(model, api:)
            base_capabilities(model, api:) + policy_optional_capabilities(model, api:)
          end

          def base_capabilities(model, api:)
            return %i[embedding] if Capabilities.embeddings?(model)

            capabilities = %i[chat]
            capabilities << :streaming if %i[generate_content raw_predict].include?(api)
            capabilities
          end

          def policy_optional_capabilities(model, api:)
            return [] if Capabilities.embeddings?(model)

            caps = []
            caps << :vision if Capabilities.vision?(model)
            caps << :tools if generate_content_model?(model) && api == :generate_content
            caps
          end

          def resolve_capability_policy(model, api:, metadata:, instance_id:)
            provider_catalog = capability_catalog_for(model, api:)
            real_caps = capability_real_for(metadata)
            provider_cfg = vertex_provider_config
            instance_cfg = vertex_instance_config(instance_id)
            model_cfg = vertex_model_config(model)

            Legion::Extensions::Llm::CapabilityPolicy.resolve(
              real: real_caps,
              provider_catalog: provider_catalog,
              probe: {},
              provider_envelope: {},
              provider_config: provider_cfg,
              instance_config: instance_cfg,
              model_config: model_cfg
            )
          end

          def capability_catalog_for(model, api:)
            return {} if Capabilities.embeddings?(model)

            catalog = {}
            catalog[:vision] = Capabilities.vision?(model)
            catalog[:tools] = api == :generate_content
            catalog[:streaming] = %i[generate_content raw_predict].include?(api)
            catalog
          end

          def capability_real_for(metadata)
            return {} unless metadata.is_a?(Hash)

            features = metadata[:supportedFeatures] || metadata['supportedFeatures']
            return {} unless features.is_a?(Hash)

            real = {}
            real[:tools] = features['functionCalling'] if features.key?('functionCalling')
            real[:vision] = features['multimodalInput'] if features.key?('multimodalInput')
            real[:thinking] = features['thinking'] if features.key?('thinking')
            real
          end

          def vertex_provider_config
            cfg = CredentialSources.setting(:extensions, :llm, :vertex)
            return {} unless cfg.is_a?(Hash)

            cfg.except(:instances, 'instances')
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vertex.provider.capability_policy_config')
            {}
          end

          def vertex_instance_config(instance_id)
            cfg = CredentialSources.setting(:extensions, :llm, :vertex)
            return {} unless cfg.is_a?(Hash)

            instances = cfg[:instances] || cfg['instances']
            return {} unless instances.is_a?(Hash)

            (instances[instance_id] || instances[instance_id.to_s] || {}).to_h
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vertex.provider.instance_config')
            {}
          end

          def vertex_model_config(model)
            cfg = CredentialSources.setting(:extensions, :llm, :vertex)
            return {} unless cfg.is_a?(Hash)

            models = cfg[:models] || cfg['models']
            return {} unless models.is_a?(Hash)

            id = short_model_id(model)
            (models[id.to_sym] || models[id.to_s] || {}).to_h
          rescue StandardError => e
            handle_exception(e, level: :warn, handled: true, operation: 'vertex.provider.model_config')
            {}
          end

          def short_model_id(model)
            id = model_id(model)
            id.include?('/') ? id.split('/').last : id
          end

          def bearer_token
            token = config.vertex_access_token
            token ? "Bearer #{token}" : nil
          end

          def credential_source
            return :access_token if config.vertex_access_token
            return :credentials_file if config.vertex_credentials

            :google_application_default_credentials
          end

          def model_id(model)
            value = model.respond_to?(:id) ? model.id : model
            self.class.resolve_model_id(value, config:)
          end

          def publisher_for(model)
            id = model_id(model)
            return publisher_from_resource(id) if id.start_with?('projects/')

            PUBLISHERS.fetch(id, default_publisher)
          end

          def publisher_from_resource(resource)
            match = resource.to_s.match(%r{/publishers/([^/]+)/models/})
            match&.[](1)
          end

          def api_for(model)
            id = model_id(model)
            return API_MODES[id] if API_MODES.key?(id)
            return :raw_predict if publisher_for(id) != default_publisher && !Capabilities.embeddings?(id)

            :generate_content
          end

          def generate_content_model?(model)
            api_for(model) == :generate_content
          end

          def usage_type_for(model)
            Capabilities.embeddings?(model) ? :embedding : :inference
          end

          def model_family_for(model, publisher = nil)
            id = model_id(model)
            return MODEL_FAMILIES[id] if MODEL_FAMILIES.key?(id)

            normalized_family(publisher || publisher_for(id))
          end

          def normalized_family(provider)
            value = provider.to_s.downcase.tr('-', '_')
            return :gemini if value == 'google'
            return :mistral if value == 'mistralai'

            value.to_sym
          end

          def alias_for(model)
            ALIASES.key(model_id(model))
          end
        end
      end
    end
  end
end
