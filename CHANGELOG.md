# Changelog

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
