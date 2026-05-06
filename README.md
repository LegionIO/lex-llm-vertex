# lex-llm-vertex

Google Cloud Vertex AI provider extension for `Legion::Extensions::Llm`.

This gem adds a hosted Vertex AI provider surface for Legion LLM routing. It keeps discovery offline by default, preserves full Vertex publisher model resource names for routing, and exposes project/location instance metadata for multi-region provider fleets. It installs against the current published `lex-llm` and `legion-llm` gems, while the `Gemfile` can use local sibling checkouts for unreleased provider-contract testing.

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

## Fleet Responder

Provider instances can opt in to consuming Legion LLM fleet requests. The provider-owned fleet actor only starts when at least one configured instance enables `respond_to_requests`.

Fleet request execution is delegated to `Legion::LLM::Fleet::ProviderResponder` when the installed `legion-llm` exposes that helper. If the helper is not available, the actor remains disabled and normal provider discovery, health, chat, streaming, embeddings, and token counting continue to load.

```yaml
extensions:
  llm:
    vertex:
      instances:
        local:
          fleet:
            enabled: true
            respond_to_requests: true
            capabilities:
              - chat
              - stream_chat
              - embed
```

## Provider Surface

```ruby
provider = Legion::Extensions::Llm::Vertex::Provider.new(Legion::Extensions::Llm.config)

provider.discover_offerings(live: false)
provider.offering_for(model: 'gemini-2.5-flash')
provider.health(live: false)
provider.chat(messages:, model:)
provider.stream_chat(messages:, model:) { |chunk| chunk.content }
provider.embed(text: 'hello', model: 'gemini-embedding-001')
provider.count_tokens(messages:, model:)
```

`discover_offerings(live: false)` returns a conservative static catalog for routing defaults and unit tests. `discover_offerings(live: true)` calls the Vertex publisher models listing endpoint and maps returned model data into `Legion::Extensions::Llm::Routing::ModelOffering` records.

## Static Model Catalog

| Model | Alias | Publisher | Family | API Mode |
|-------|-------|-----------|--------|----------|
| gemini-2.5-flash | gemini-flash | google | gemini | generateContent |
| gemini-2.5-pro | gemini-pro | google | gemini | generateContent |
| gemini-embedding-001 | gemini-embedding | google | gemini | predict (embedding) |
| text-embedding-005 | text-embedding | google | gemini | predict (embedding) |
| claude-sonnet-4-5 | claude-sonnet | anthropic | anthropic | rawPredict |
| mistral-medium-3 | mistral-medium | mistralai | mistral | rawPredict |
| llama-4-maverick | llama-4-maverick | meta | meta | rawPredict |

## Model Offerings

Every offering uses:

- `provider_family: :vertex`
- `transport: :http`
- the full Vertex publisher model resource name as `model`
- `metadata[:model_family]` inferred from the publisher/model or accepted from the caller
- `metadata[:project]` and `metadata[:location]` copied from the provider instance

Known aliases are intentionally small and configurable. For example, `gemini-flash` resolves to `gemini-2.5-flash`, while the offering preserves `projects/{project}/locations/{location}/publishers/google/models/gemini-2.5-flash`.

## Registry Events

When transport is available, the `RegistryPublisher` publishes best-effort readiness and offering availability events to the `llm.registry` topic exchange using `lex-llm` registry envelopes. Events are published asynchronously in background threads and never block the caller.

## File Map

| Path | Purpose |
|------|---------|
| `lib/legion/extensions/llm/vertex.rb` | Namespace module, default settings, provider registration |
| `lib/legion/extensions/llm/vertex/provider.rb` | Vertex AI provider: chat, stream, embed, count_tokens, health, discovery |
| `lib/legion/extensions/llm/vertex/fleet_responder.rb` | Optional bridge to the shared `legion-llm` provider fleet responder |
| `lib/legion/extensions/llm/vertex/actors/fleet_worker.rb` | Legion subscription actor for provider-owned fleet request consumption |
| `lib/legion/extensions/llm/vertex/runners/fleet_worker.rb` | Runner entrypoint that delegates fleet request execution to `legion-llm` |
| `lib/legion/extensions/llm/vertex/version.rb` | `VERSION` constant |

## Observability

All modules and classes use `Legion::Logging::Helper` for structured logging:

- **Info-level logging** on key provider actions: `chat`, `stream`, `embed`, `count_tokens`, `discover_offerings`, `health`, and registry publish operations
- **Every rescue block** calls `handle_exception(e, level:, handled:, operation:)` with dot-separated operation names (e.g. `vertex.provider.health`, `vertex.registry.publish_event`)
- **Level conventions**: `:warn` for recoverable failures, `:error` for unexpected errors, `:debug` for expected/best-effort failures (transport unavailable, etc.)

## API Contract

The implementation is intentionally limited to Vertex AI REST surfaces documented by Google Cloud:

- `generateContent` and `streamGenerateContent` for Gemini publisher models
- `countTokens` for Gemini-style publisher models
- `predict` for documented text embedding models
- `rawPredict` and `streamRawPredict` endpoint builders for partner publisher models such as Mistral, Anthropic, and Meta

Provider-specific request bodies are not guessed. Partner raw-predict chat requests use the message shape documented for those partner model endpoints; embeddings are only implemented for documented Vertex text embedding models.

## Development

```bash
bundle install
bundle exec rspec --format json --out tmp/rspec_results.json --format progress --out tmp/rspec_progress.txt
bundle exec rubocop -A
```

## License

MIT

## References

- [Vertex AI GenAI REST API](https://cloud.google.com/vertex-ai/generative-ai/docs/reference/rest)
- [Generate content with the Gemini API in Vertex AI](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/inference)
- [Text embeddings API](https://cloud.google.com/vertex-ai/generative-ai/docs/model-reference/text-embeddings-api)
- [Mistral AI models on Vertex AI](https://cloud.google.com/vertex-ai/generative-ai/docs/partner-models/mistral)
