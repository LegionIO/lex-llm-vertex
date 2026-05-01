# Changelog

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
