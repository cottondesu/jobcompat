# jobcompat v0.2.1 implementation plan

Status: implemented

## Delivery sequence

1. Extract the Prism-based Client String worker-name check into the internal `Jobcompat::CanonicalWorkerName.parse` (`lib/jobcompat/canonical_worker_name.rb`), which requires `prism` itself and depends on neither Analyzer nor Config.
2. Migrate `Analyzer#client_worker` to the shared validator, keeping `exact_string` and `unsupported_client_payload` behavior unchanged.
3. Migrate `Config.validate` `ignore[].worker` to the shared validator, removing the handwritten regex grammar and keeping the existing `ignore[N].worker is invalid` config error.
4. Add a focused validator unit matrix (accepted names, rejected syntax, invalid bytes, no normalization, standalone loading) and a producer/Config agreement check; extend Config unit tests for Unicode acceptance, invalid bytes, duplicates, and exact matching.
5. Add temporary-Git integration coverage for decomposed Unicode JC003 suppression with JSON and text audit, precomposed/decomposed exact-match guards, qualified Unicode names, non-canonical and invalid-byte config errors, and byte determinism.
6. Raise the gem version to 0.2.1 (JSON schema 2 and config version 1 unchanged) and synchronize README, CHANGELOG, architecture, and the normative delta.
7. Run the full suite on the supported Ruby matrix with Prism 1.9.0, syntax checks, gem build/contents/isolated install, CLI exit-code smoke scenarios, and diff self-review.

## Scope boundaries

No rule, finding field, uncertainty reason, config key, dependency, or release operation is added. Constant AST resolution, `DefinedConstantIndex`, the engine, formatter, and Git access are unchanged.
