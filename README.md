# lex-llm-vertex

Google Cloud Vertex AI provider extension for `Legion::Extensions::Llm`.

This gem adds a hosted Vertex AI provider surface for Legion LLM routing without depending on the old `legion-llm` gem. It keeps discovery offline by default, preserves full Vertex publisher model resource names for routing, and exposes project/location instance metadata for multi-region provider fleets. It requires `lex-llm >= 0.1.5` for the shared model offering, alias, readiness, and fleet lane contract.

## Install

```ruby
gem 'lex-llm-vertex'
```

## Configuration

The provider registers the `:vertex` provider family with `Legion::Extensions::Llm::Provider`.

```ruby
require 'legion/extensions/llm/vertex'

Legion::Extensions::Llm.configure do |config|
  config.vertex_project = ENV['GOOGLE_CLOUD_PROJECT']
  config.vertex_location = ENV.fetch('VERTEX_LOCATION', 'us-central1')
  config.vertex_access_token = ENV['VERTEX_ACCESS_TOKEN']
end
```

`vertex_access_token` is optional for local routing metadata and tests. For live calls, provide a Google Cloud access token through configuration or use Application Default Credentials in the process that owns HTTP authentication.

Default settings expose `env://` references and keep live discovery disabled:

```ruby
Legion::Extensions::Llm::Vertex.default_settings
```

## Provider Surface

```ruby
provider = Legion::Extensions::Llm::Vertex::Provider.new(Legion::Extensions::Llm.config)

provider.discover_offerings(live: false)
provider.offering_for(model: 'gemini-2.5-flash')
provider.health(live: false)
provider.chat(messages, model: model)
provider.stream(messages, model: model) { |chunk| chunk.content }
provider.embed('hello', model: 'gemini-embedding-001')
provider.count_tokens(messages, model: model)
```

`discover_offerings(live: false)` returns a conservative static catalog for routing defaults and unit tests. `discover_offerings(live: true)` calls the Vertex publisher models listing endpoint and maps returned model data into `Legion::Extensions::Llm::Routing::ModelOffering` records.

## Model Offerings

Every offering uses:

- `provider_family: :vertex`
- `transport: :http`
- the full Vertex publisher model resource name as `model`
- `metadata[:model_family]` inferred from the publisher/model or accepted from the caller
- `metadata[:project]` and `metadata[:location]` copied from the provider instance

Known aliases are intentionally small and configurable. For example, `gemini-flash` resolves to `gemini-2.5-flash`, while the offering preserves `projects/{project}/locations/{location}/publishers/google/models/gemini-2.5-flash`.

## API Contract

The implementation is intentionally limited to Vertex AI REST surfaces documented by Google Cloud:

- `generateContent` and `streamGenerateContent` for Gemini publisher models
- `countTokens` for Gemini-style publisher models
- `predict` for documented text embedding models
- `rawPredict` and `streamRawPredict` endpoint builders for partner publisher models such as Mistral, Anthropic, and Meta

Provider-specific request bodies are not guessed. Partner raw-predict chat requests use the message shape documented for those partner model endpoints; embeddings are only implemented for documented Vertex text embedding models.

Google Cloud references:

- [Vertex AI GenAI REST API](https://cloud.google.com/vertex-ai/generative-ai/docs/reference/rest)
- [Generate content with the Gemini API in Vertex AI](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference)
- [Text embeddings API](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/text-embeddings-api)
- [Mistral AI models on Vertex AI](https://cloud.google.com/vertex-ai/generative-ai/docs/partner-models/mistral)
