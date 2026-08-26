# Changelog

## [0.3.5] - 2026-08-20

0.8.0 conformance release against the lex-llm 0.8.0 contract cut.

### Changed
- Migrate the provider to the lex-llm 0.8.0 canonical contract: `chat`/`stream_chat` run through the base's single `complete` funnel (central `enforce_canonical_messages!` — the provider no longer re-implements the check), `render_payload` renders the Vertex wire FROM canonical values, `parse_completion_response` returns a `Canonical::Response`, and `build_chunk` yields `Canonical::Chunk` objects through the base `Streaming` module (real SSE chunk lifecycle ending in exactly one done chunk).
- Enforce the canonical dispatch boundary end to end: the callable's chat, stream_chat, and count_tokens operations keep the shared `Provider#enforce_canonical_messages!` call at the exact-execution boundary, and the base funnel enforces centrally before rendering — plain-Hash messages (the 2026-08-19 incident class) raise a loud ArgumentError at both boundaries, and the dual-shape render-seam tolerance (provider-native `Message` acceptance) is gone.
- `count_tokens` returns the provider's real `totalTokens` as an Integer and raises `NotImplementedError` for non-generateContent partner models (unsupported operations fail loud; the discovery writer publishes `:unsupported` operation evidence for them).
- `embed` returns the 0.8.0 documented artifact `{ text:, model:, embedding:, usage: Canonical::Usage }`.
- The provider's offering read path now serves activated inventory offerings from the SSOT registry snapshot (base `discover_offerings`, 07 C5); the discovery actor's writer remains the sole publication path.
- Raise the `lex-llm` dependency floor to 0.8.0.

### Added
- Vertex wire `finishReason` spellings map to canonical stop reasons via `StopReasonMapping#stop_reason_map_additions`; sync responses and rawPredict partner responses carry `stop_reason`.
- Vertex `thought` parts surface as a canonical `Thinking` member (content + `thoughtSignature`) in sync responses and as `thinking_delta` chunks in streams, instead of being dropped.
- The fleet worker runner dispatches protocol-v3 exact-only envelopes against the SSOT registry (`ProviderResponder.call` with `registry:`).
- Conformance: the ssot_v3 spec runs the shared kit's B1 (central canonical enforcement) and B2 (canonical outputs, asserted by type) groups against the real callable boundary, and the raw-string model dispatch examples now feed canonical messages through the real render path.
- Keep a local-tree `lex-llm` path dependency in the test group so the adjacent checkout resolves against the unreleased 0.8.0 cut during development.

### Removed
- Legacy type construction in the parse paths: `Llm::Message` / `Llm::Chunk` / `Llm::ToolCall` from completion parsing, `Llm::Content` / `Llm::Content::Raw` handling in the content renderer, and `Llm::Embedding` from the embed path (replaced by `Canonical::*` types and the documented embedding artifact).
- The provider-native offering production path: the `discover_offerings` override, `offering_for` / `static_offerings` / `offering_from_live_model` / `offering_from_model` / `build_offering` (the `Routing::ModelOffering` production site), and the now-dead offering-feed helpers.
- The discovery actor's `Inventory::ScopedRefresher::LegacyCoordinatorAdapter` wiring (the file and the mixed-version window it served are deleted in lex-llm 0.8.0); the Publisher is a direct Registry wrapper.

## [0.3.4] - 2026-08-19

### Changed
- Publish the validated four-axis lane-weight pair from every Vertex offering draft and reconcile weight-only changes atomically on the existing discovery cadence.
- Track initializing publications through readiness, serialize replacement/removal state, and report dormant configured weights without adding a Settings callback or operator workflow.
- Add callable-to-HTTP conformance coverage proving folded system messages render in Vertex's native `systemInstruction` field.

### Fixed
- Validate startup offering weights before creating a callable or claiming its inventory scope, so malformed settings leave no untracked initializing publication and the next valid cadence pass recovers without operator action.
- Pin the raw-`Data` comparison exception with real-cadence regressions: frozen static catalog order and the per-instance evidence timestamp keep unchanged passes stable, while every authoritative draft member and duplicate-count change remains significant.

## [0.3.3] - 2026-08-18

### Fixed
- Update SSOT v3 conformance coverage: `default` is a valid operator configuration
  name for an instance, rather than a reserved identity.

## [0.3.2] - 2026-08-17

### Changed
- **SSOT v3 fail-forward identity** — Instance identity is now the operator's CONFIG NAME
  (the key the router's `instances.<name>` settings lookups use); the derived
  `{project}:{location}/{credential_fingerprint}` moves to the secondary `InstanceKey`
  `physical_id` field (dedup/diagnostics only). Two config names pointing at the same
  physical endpoint stay distinct instances. `DiscoveryRefreshConfigHelpers#derive_instance_id`
  becomes `derive_physical_id`; all `Inventory::Publisher` calls carry the `physical_id:`
  secondary field. Requires `lex-llm >= 0.7.1` (InstanceKey `physical_id` field).
- **Embedding models publish `chat: :unsupported`** — embedding offerings from the
  STATIC_MODELS catalog publish `embed` as `:supported` and `chat`/`stream_chat`/
  `count_tokens` as `:unsupported`, so a chat request can never be routed to an
  embedding-only model; chat models publish `chat`/`stream_chat` `:supported`
  (`count_tokens` gated on generate-content support).
- `lex-llm` dependency floor bumped to `>= 0.7.1` (InstanceKey `physical_id` field).
- Conformance/actor specs updated to the name-based identity with the secondary
  physical-id field; the conformance harness fixture is now a name-keyed instance map.
- **Single actor registration** — the provider module no longer extends `Core` at
  file level, so the boot-time submodule walk's `autobuild` gate skips it and the
  gem's own top-level extension load is the sole actor registration (eliminates the
  double-claim / FencedPublisherError from the daemon's dual boot-time build).

## [0.3.1] - 2026-08-13

### Changed
- Remove all inline `rubocop:disable` directives from lib/ and spec/; fix underlying offenses by
  real refactoring: rename unused `headers:` kwarg to `_headers:` in `complete`, move spec files to
  paths that match the described class (`capability_policy_spec.rb` → `provider_spec.rb`,
  `actors/fleet_worker_spec.rb` → `actor/fleet_worker_spec.rb`), and disable `Metrics/ClassLength`
  at project level (consistent with all other disabled Metrics cops in `.rubocop.yml`).
- Remove secondary publication engine: strip `attr_writer :registry_publisher`, the
  `registry_publisher` class method, and all `publish_models_async`/`publish_readiness_async`
  calls from `Provider`. Discovery publication now flows exclusively through the SSOT v3
  `DiscoveryRefresh` actor via `Inventory::Publisher`.
- Remove `:default` identity access in `Provider#settings`; `project` now reads
  `config.vertex_project || ENV['GOOGLE_CLOUD_PROJECT']`, `location` reads `config.vertex_location`
  directly, `default_publisher` returns the provider-native literal `'google'`.
- Remove `respond_to?(:vertex_model_aliases)` guard in `resolve_model_id`; use safe navigation
  (`config&.vertex_model_aliases`) instead.
- Rename fallback instance key in `DiscoveryRefreshConfigHelpers#configured_instances` from
  `:default_instance` to `:settings` to avoid gate-A false match on `:default` prefix.
- Add `handle_exception` call to the `check_health` rescue block so failures are logged through
  the standards path before a `ReadinessResult` is returned.
- Update `vertex_spec.rb` to remove `RegistryPublisher` test stubs and expectations that no
  longer apply; replace with direct assertions on model/offering/readiness values.

## [0.3.0] - 2026-08-13

### Changed
- **SSOT v3 provider migration** — Complete rewrite of the discovery actor to the
  Inventory::Publisher pattern. Claims instances by `{project}:{location}/{credential_fingerprint}`,
  discovers models from the STATIC_MODELS catalog, probes health via the non-inference
  models-list endpoint, and publishes OfferingDraft snapshots with full operation/capability evidence.
- Remove `@model || STATIC_MODELS.first` default-model fallbacks from `completion_url`/`stream_url`.
- Remove `Legion::LLM::Call::Registry` and `ScopedRefresher` dependencies from the discovery actor.
- Add `VertexCallable` with `disconnect` and `normalize_dispatch_error(error:)` contracts.
- Add SSOT v3 conformance spec with `it_behaves_like 'an SSOT v3 provider adapter'`.
- Bump `lex-llm` dependency floor to `>= 0.7.0`.
- `publication_source: :provider_static_catalog` for all offerings derived from STATIC_MODELS.
- Two distinct projects/locations produce independent instances with separate lanes.
- Initial readiness failure leaves instance in `:initializing` state (not `:unavailable`).
- Error normalization (§8 health firewall): only an explicit flat 503 SERVICE_UNAVAILABLE
  response body maps to `instance_unavailable`; connection_failure, timeout, overload (503/529),
  model_not_ready, 429 (rate_limited), auth errors, and generic 5xx are all request-local/terminal
  and never mutate global instance availability.
- Remove `instance_id: :default` from `offering_for`/`build_offering`; callers receive a
  real project+location derived instance_id from `provider_instance_id`.
- Read `settings[:publisher]` and `settings[:location]` directly (registered defaults applied);
  remove inline `|| 'google'` and `|| 'us-central1'` fallback guards.

## [0.2.16] - 2026-08-04

### Changed
- Advance patch-release metadata to keep the Vertex provider aligned with the coordinated Legion LLM provider release set. No runtime behavior changes are included.

## [0.2.15] - 2026-06-20

### Changed
- Align Vertex offerings to the current `lex-llm` contract: shared `discover_offerings` now rebuilds
  resource-name offerings from discovered models, preserves provider health on offerings, and keeps the
  shared capability-override path intact.
- Fix the provider tail introduced during the contract refactor so the provider file closes cleanly again.

## [0.2.14] - 2026-06-19

### Changed
- Adopt `Legion::Extensions::Llm::Inventory::ScopedRefresher` mixin (lex-llm 0.6.0). Discovery
  refresh actors now write directly to the live `Inventory` catalog via `Inventory.write_lane`.
- Pin `lex-llm >= 0.6.0` and `legion-llm >= 0.14.0` in gemspec.
- Standard `weight: 100` default added to provider instance settings schema.

## 0.2.13 - 2026-06-16

- Dependency updates and code quality improvements.

## 0.2.12 - 2026-06-15

- **CapabilityPolicy integration** — Model-family heuristics tagged as `:provider_catalog`; Vertex features as `:model_metadata`. Settings overrides at provider/instance/model level supported.

## 0.2.11 - 2026-06-13

- **Gemfile cleanup** — Remove local path overrides; dependencies resolve from gemspec via rubygems.
- **Dependency bump** — Require `lex-llm >= 0.5.0` for canonical types support.
- **Canonical tool support** — Use `ToolSchema.extract` and add `:tools` capability.
- **Bug fix** — Handle Array tool_calls in `tool_call_parts`.
- 29 examples, 0 failures; 13 files, 0 rubocop offenses.

## 0.2.10 - 2026-06-02

- Add per-provider scoped discovery refresh actor

## 0.2.9 - 2026-05-21

- Add `default_transport`/`default_tier` class declarations, remove `configured_transport`/`configured_tier`
- Remove `DEFAULT_LOCATION`/`DEFAULT_PROJECT`/`DEFAULT_PUBLISHER` constants — now read from settings
- Add `model_allowed?` filtering in `discover_offerings`
- Default tier corrected from :frontier to :cloud
- Identity headers included via base provider


## 0.2.8 - 2026-05-18

- Fix streaming tool calls: `build_chunk` now passes `tool_calls: parse_tool_calls(parts)` to the Chunk constructor. Previously tool calls were omitted from streaming responses entirely.


## 0.2.7 - 2026-05-08

- Accept keyword arguments in `list_models` to match the base provider contract called by `discover_offerings`.

## 0.2.6 - 2026-05-06

- Load provider-owned fleet actors through the LegionIO subscription base and the canonical Vertex provider root.
- Keep fleet runners anchored on the provider root namespace so provider constants and instance discovery are always loaded.
- Preserve configured transport and tier metadata when Vertex builds routing offerings.
- Remove throwaway unused-argument allocation in provider request methods.
- Gate release publishing on the shared security workflow.

## 0.2.5 - 2026-05-06

- Use the shared `lex-llm` fleet provider responder helper for provider-owned fleet workers.
- Remove the runtime `legion-llm` dependency and require `lex-llm >= 0.4.3` for responder-side fleet execution.

## 0.2.4 - 2026-05-06

- Keep clean CI installs on published RubyGems dependency floors while preserving local path overrides for unreleased sibling integration testing.
- Add a `stream_chat` compatibility alias so Vertex exposes the shared provider streaming surface even when running against older published `lex-llm` versions.
- Register Vertex configuration options directly when the installed `lex-llm` does not expose `Configuration.register_provider_options`.
- Make the provider-owned fleet responder bridge load only when the installed `legion-llm` exposes `Legion::LLM::Fleet::ProviderResponder`; fleet actors stay disabled instead of breaking gem load when that helper is unavailable.
- Refresh README dependency, fleet responder, file-map, license, and development-command guidance.

## 0.2.3 - 2026-05-06

- Remove require-time provider self-registration; `legion-llm` now owns adapter creation and registry writes from loaded provider discovery metadata.
- Bump dependency floors to `lex-llm >= 0.4.1` and `legion-llm >= 0.9.1`.

## 0.2.2 - 2026-05-06

- Enforce the shared keyword-only `lex-llm` provider contract for chat, embeddings, and token counting.
- Move Vertex defaults back to `Legion::Extensions::Llm.provider_settings` with credentials/provider metadata under the default instance and instance-level fleet responder settings.
- Add provider-owned fleet responder actor and runner backed by `legion-llm` fleet policy execution.
- Bump the transport dependency floor to `legion-transport >= 1.4.14`.

## 0.2.1 - 2026-05-03

- Normalize generic settings keys to Vertex provider config keys during instance discovery.

## 0.2.0 - 2026-05-01

- Add auto-discovery via CredentialSources and AutoRegistration from lex-llm 0.3.0
- Self-register discovered instances into Call::Registry at require-time
- Require lex-llm >= 0.3.0


## [0.1.5] - 2026-04-30

- Add `Legion::Logging::Helper` to all modules and classes for structured logging
- Replace ad-hoc `log_publish_failure` with `handle_exception` in RegistryPublisher
- Add `handle_exception` to every rescue block with correct level, handled, and operation
- Add info-level logging for key provider actions: chat, stream, embed, count_tokens, discover_offerings, health
- Update README to reflect current architecture, file map, and observability conventions

## [0.1.4] - 2026-04-30

- Add headers: parameter to complete method for base provider contract compliance

## 0.1.3 - 2026-04-28

- Remove the unused runtime `legion/settings` require while preserving the gemspec dependency.

## 0.1.2 - 2026-04-28

- Publish best-effort `llm.registry` live readiness and live publisher-model availability events using `lex-llm` registry envelopes when transport is already available.

## 0.1.1 - 2026-04-28

- Require `lex-llm >= 0.1.5` for the shared model offering, alias, readiness, and fleet lane contract used by Vertex routing metadata.

## 0.1.0 - 2026-04-28

- Initial Legion::Extensions::Llm Vertex AI provider extension scaffold.
- Add offline provider defaults, project/location-aware model offering mapping, Vertex publisher model endpoint construction, chat, streaming, embeddings, token-counting metadata, health, and live discovery entrypoints.
- Add README, gemspec, CI, and stubbed unit specs for Vertex AI routing behavior.
