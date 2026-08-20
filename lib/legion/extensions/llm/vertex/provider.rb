# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/extensions/llm'
require 'securerandom'

module Legion
  module Extensions
    module Llm
      module Vertex
        # Google Cloud Vertex AI provider implementation for the Legion::Extensions::Llm
        # 0.8.0 canonical contract.
        #
        # The base funnel (chat/stream_chat -> complete) is the single completion
        # path: it enforces Canonical::Message inputs centrally and returns
        # Canonical::Response (sync) or yields Canonical::Chunk (stream). This
        # class owns the Vertex wire dialect only — render_payload renders FROM
        # canonical values; parse_completion_response and build_chunk parse TO
        # canonical types (08 R1-R4). The provider-native offering read path is
        # gone: discover_offerings serves the SSOT registry snapshot (07 C5) and
        # the discovery actor's writer is the sole publication path.
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

          # The base funnel posts to these model-scoped endpoints. render_payload
          # pins @model before the base sync/stream response path resolves them.
          def completion_url
            raise ArgumentError, 'model is required for completion_url' if @model.nil?

            chat_url(@model, stream: false)
          end

          def stream_url
            raise ArgumentError, 'model is required for stream_url' if @model.nil?

            chat_url(@model, stream: true)
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

          def count_tokens(messages:, model:, params: nil)
            _ = [params]
            model_id = model_id(model)
            unless generate_content_model?(model_id)
              raise NotImplementedError, "Vertex countTokens for #{model_id} is not standardized"
            end

            enforce_canonical_messages!(messages)
            payload = { contents: format_messages(messages) }
            response = connection.post(count_tokens_url(model: model_id), payload)
            response.body['totalTokens']
          end

          def embed(text:, model:, dimensions: nil, task_type: nil, title: nil, params: nil, headers: {})
            _ = [params]
            enforce_model_allowed!(model)
            model_id = model_id(model)
            unless Capabilities.embeddings?(model_id)
              raise NotImplementedError, "Vertex embedding payload for #{model_id} is not standardized"
            end

            instances = Array(text).map { |item| embedding_instance(item, task_type:, title:) }
            parameters = { outputDimensionality: dimensions }.compact
            payload = { instances: instances, parameters: parameters }
            response = connection.post(embedding_url(model: model_id), payload) do |req|
              req.headers = headers.merge(req.headers) unless headers.empty?
            end
            parse_embedding_response(response, model: model_id, text: text)
          end

          private

          # One request-render boundary (08 R1): renders the Vertex wire FROM
          # canonical values. The Selection-derived model is resolved through
          # the alias table and pinned for the model-scoped endpoints; it is
          # never defaulted or re-selected (B4).
          def render_payload(messages, tools:, tool_prefs:, model:, stream:, schema:, thinking:, params:)
            model_id = model_id(model)
            @model = model_id
            if generate_content_model?(model_id)
              generate_content_payload(messages, tools:, tool_prefs:, schema:, thinking:, params:)
            else
              raw_predict_payload(messages, model_id, stream:, params:)
            end
          end

          def generate_content_payload(messages, tools:, tool_prefs:, schema:, thinking:, params:)
            {
              contents: format_messages(messages.reject { |message| message.role == :system }),
              systemInstruction: system_instruction(messages),
              generationConfig: generation_config(params, schema, thinking),
              tools: format_tools(tools),
              toolConfig: tool_config(tool_prefs)
            }.compact
          end

          def raw_predict_payload(messages, model_id, stream:, params:)
            {
              model: model_id,
              messages: messages.reject { |message| message.role == :system }.map do |message|
                { role: raw_role(message.role), content: message.text }
              end,
              temperature: maybe_normalize_temperature(params),
              max_tokens: params&.max_tokens,
              stream: stream
            }.compact
          end

          def generation_config(params, schema, thinking)
            {
              temperature: maybe_normalize_temperature(params),
              maxOutputTokens: params&.max_tokens,
              responseMimeType: ('application/json' if schema),
              responseSchema: schema_hash(schema),
              thinkingConfig: thinking_config(thinking)
            }.compact
          end

          def schema_hash(schema)
            return unless schema

            schema.respond_to?(:to_h) ? schema.to_h.fetch(:schema, schema.to_h) : schema
          end

          # Canonical::Thinking::Config -> Vertex thinkingBudget (R4): the token
          # budget is Vertex's dialect axis; effort is derived through the
          # shared effort<->budget SSOT on the canonical type.
          def thinking_config(thinking)
            return nil unless thinking.is_a?(Canonical::Thinking::Config)

            { thinkingBudget: thinking.resolved_budget }.compact
          end

          def system_instruction(messages)
            parts = messages.select { |message| message.role == :system }
                            .flat_map { |message| content_parts(message.content) }
            return nil if parts.empty?

            { parts: parts }
          end

          # Render seam (08 R1): canonical messages -> Vertex contents/parts.
          # Input enforcement is central (the base funnel and the callable
          # boundary) — this method renders and nothing else.
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
            tool_calls = message.tool_calls
            return tool_call_parts(message) if tool_calls && !tool_calls.empty?

            tool_call_id = message.tool_call_id
            return tool_result_parts(message) if tool_call_id && !tool_call_id.empty?

            content_parts(message.content)
          end

          # Canonical content (String | ContentBlock | Array<ContentBlock> | nil)
          # -> Vertex parts. One shape, one code path (04 L2, 10 §4).
          def content_parts(content)
            return [] if content.nil?
            return [{ text: content }] if content.is_a?(::String)
            return content_block_parts(content) if content.is_a?(Canonical::ContentBlock)

            content.flat_map { |block| content_block_parts(block) }
          end

          def content_block_parts(block)
            return [{ text: block.text }] if block.text?
            return [] if block.data.nil? || block.media_type.nil?

            [{ inlineData: { mimeType: block.media_type, data: block.data } }]
          end

          def tool_call_parts(message)
            # Array<Canonical::ToolCall> is the canonical shape.
            message.tool_calls.map do |tool_call|
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

          # One response-parse boundary (08 R2): parses TO Canonical::Response.
          def parse_completion_response(response)
            body = response.body
            if generate_content_model?(@model)
              parse_generate_content_response(body)
            else
              parse_raw_predict_response(body)
            end
          end

          def parse_generate_content_response(body)
            parts = response_parts(body)
            Canonical::Response.build(
              text: text_content(parts),
              thinking: thinking_from_parts(parts),
              tool_calls: parse_tool_calls(parts),
              usage: usage_from_metadata(body['usageMetadata']),
              stop_reason: stop_reason_lookup(body.dig('candidates', 0, 'finishReason')),
              model: body['modelVersion'] || @model
            )
          end

          def parse_raw_predict_response(body)
            choice = Array(body['choices']).first || {}
            message = choice['message'] || {}
            usage = body['usage'] || {}
            Canonical::Response.build(
              text: message['content'] || choice['text'],
              usage: if usage.empty?
                       nil
                     else
                       Canonical::Usage.build(
                         input_tokens: usage['prompt_tokens'],
                         output_tokens: usage['completion_tokens']
                       )
                     end,
              stop_reason: stop_reason_lookup(choice['finish_reason']),
              model: body['model'] || @model
            )
          end

          # One chunk-parse boundary (08 R2): parses one SSE data event TO
          # Canonical::Chunk (or an Array of them). The done/error lifecycle is
          # owned by the base Streaming module.
          def build_chunk(data)
            chunks = generate_content_model?(@model) ? generate_content_chunks(data) : raw_predict_chunks(data)
            return nil if chunks.empty?

            chunks.size == 1 ? chunks.first : chunks
          end

          def generate_content_chunks(data)
            candidate = data.dig('candidates', 0) || {}
            chunks = []
            (candidate.dig('content', 'parts') || []).each_with_index do |part, index|
              chunks.concat(generate_content_part_chunks(part, index:))
            end
            usage = usage_from_metadata(data['usageMetadata'])
            chunks << Canonical::Chunk.usage_chunk(usage:, request_id: nil) if usage
            chunks
          end

          def generate_content_part_chunks(part, index:)
            function_call = part['functionCall']
            if function_call
              [
                Canonical::Chunk.tool_call_delta(
                  tool_call: {
                    name: function_call['name'],
                    arguments: Legion::JSON.generate(function_call['args'] || {}),
                    index:
                  },
                  request_id: nil
                )
              ]
            elsif part['thought']
              text = part['text'].to_s
              return [] if text.empty? && part['thoughtSignature'].nil?

              [Canonical::Chunk.thinking_delta(delta: text, request_id: nil, signature: part['thoughtSignature'])]
            elsif part['text']
              [Canonical::Chunk.text_delta(delta: part['text'], request_id: nil)]
            else
              []
            end
          end

          def raw_predict_chunks(data)
            choice = Array(data['choices']).first || {}
            delta = choice['delta'] || choice['message'] || {}
            content = delta['content']
            return [] unless content

            [Canonical::Chunk.text_delta(delta: content.to_s, request_id: nil)]
          end

          def response_parts(body)
            body.dig('candidates', 0, 'content', 'parts') || []
          end

          def text_content(parts)
            text = parts.reject { |part| part['thought'] }.filter_map { |part| part['text'] }.join
            text.empty? ? nil : text
          end

          # Vertex thought parts are the provider's reasoning dialect (R4):
          # they surface as a canonical Thinking, never dropped into text.
          def thinking_from_parts(parts)
            thought_parts = parts.select { |part| part['thought'] }
            return nil if thought_parts.empty?

            content = thought_parts.filter_map { |part| part['text'] }.join
            signature = thought_parts.filter_map { |part| part['thoughtSignature'] }.first
            return nil if content.empty? && signature.nil?

            Canonical::Thinking.build(content:, signature:)
          end

          def output_tokens(usage)
            candidates = usage['candidatesTokenCount'] || 0
            thoughts = usage['thoughtsTokenCount'] || 0
            total = candidates + thoughts
            total.positive? ? total : nil
          end

          # Vertex usageMetadata -> canonical usage keys (edge translation, O03a).
          def usage_from_metadata(metadata)
            return nil unless metadata.is_a?(Hash) && !metadata.empty?

            Canonical::Usage.build(
              input_tokens: metadata['promptTokenCount'],
              output_tokens: output_tokens(metadata),
              cache_read_tokens: metadata['cachedContentTokenCount'],
              thinking_tokens: metadata['thoughtsTokenCount']
            )
          end

          # Sync tool calls: the Vertex wire carries functionCall.args as a
          # native JSON object (Hash) — already the canonical arguments type.
          # A malformed wire (missing name, non-Hash args) raises at the
          # canonical factory, never a fabricated call.
          def parse_tool_calls(parts)
            parts.filter_map do |part|
              function_call = part['functionCall']
              next nil unless function_call

              Canonical::ToolCall.build(
                name: function_call['name'],
                arguments: function_call['args'] || {}
              )
            end
          end

          # 05 §3 documented artifact: { text:, model:, embedding: Array<Float>,
          # usage: Canonical::Usage }.
          def parse_embedding_response(response, model:, text:)
            predictions = response.body['predictions'] || []
            vectors = predictions.map do |prediction|
              prediction['embeddings']&.fetch('values', nil) || prediction['values']
            end
            vectors = vectors.first if vectors.length == 1
            statistics = predictions.first&.dig('embeddings', 'statistics') || {}
            {
              text: text,
              model: model,
              embedding: vectors,
              usage: Canonical::Usage.build(input_tokens: statistics['token_count'] || 0)
            }
          end

          def embedding_instance(text, task_type:, title:)
            { content: text, task_type: task_type, title: title }.compact
          end

          # Vertex wire finishReason spellings (R4: dialect at the provider
          # edge). Unmapped reasons resolve to nil, mirroring the shared
          # reference implementation.
          def stop_reason_map_additions
            {
              'STOP' => :end_turn,
              'MAX_TOKENS' => :max_tokens,
              'SAFETY' => :content_filter,
              'PROHIBITED_CONTENT' => :content_filter,
              'RECITATION' => :content_filter,
              'SPII' => :content_filter,
              'IMAGE_SAFETY' => :content_filter,
              'MALFORMED_FUNCTION_CALL' => :error,
              'FINISH_REASON_UNSPECIFIED' => :end_turn
            }
          end

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

          def publisher_parent
            "projects/#{project}/locations/#{location}/publishers/#{default_publisher}/models"
          end

          def publisher_model_path(model)
            id = model_id(model)
            return id.delete_prefix("#{api_base}/") if id.start_with?('projects/')

            "projects/#{project}/locations/#{location}/publishers/#{publisher_for(id)}/models/#{id}"
          end

          def chat_url(model, stream:)
            return raw_predict_url(model:, stream:) unless generate_content_model?(model)

            stream ? stream_generate_content_url(model:) : generate_content_url(model:)
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
        end
      end
    end
  end
end
