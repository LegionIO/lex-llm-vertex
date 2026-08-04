# Changelog

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
