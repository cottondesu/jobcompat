# jobcompat v0.2 normative delta specification

Status: normative for `0.2.0`

This document is a delta from [`spec-v0.1.md`](spec-v0.1.md). **v0.1 rules remain normative unless explicitly overridden here.** JC001–JC007, their severity and precedence, the three deployment directions, immutable Git inputs, source-only Prism analysis, and conservative unknown behavior are unchanged.

## 1. Versioned contracts

- Gem and CLI version: `0.2.0`.
- JSON `schema_version`: `2`.
- `.jobcompat.yml` version: `1`.
- JSON schema v2 preserves the v1 field structure. Its intentional public expansion is the producer `unknown_reason` vocabulary.

## 2. Supported producer syntax

In addition to all v0.1 forms, v0.2 recognizes:

- `Worker.perform_bulk(rows, **options)`;
- `Worker.set(...).perform_in(schedule, *payload)` and `.perform_at(time, *payload)`;
- `Worker.set(...).perform_bulk(rows, **options)`;
- `Sidekiq::Client.push(payload)` and `::Sidekiq::Client.push(payload)`;
- `Sidekiq::Client.push_bulk(payload)` and its root-qualified form.

Only the exact static Client receiver is recognized. Client instances, `via`, wrappers, similarly named receivers, ActiveJob, inline/sync execution, and other bulk-like method names remain unsupported or ignored as defined by the v0.1 evidence policy.

## 3. Bulk normalization

A static outer Array is inspected without evaluating inner values. Each inner Array with no splat contributes its element count. Duplicate counts are removed and sorted. One callsite therefore emits at most one producer fact per distinct known arity, plus uncertainty evidence. `[]` emits no producer fact and no warning.

Non-Array rows and rows containing a splat emit `dynamic_bulk_arguments`; known sibling rows remain known. A dynamic outer collection emits only that unknown evidence. Explicit `at`, `batch_size`, and `spread_interval` options do not contribute to payload arity. A keyword splat that could override bulk class or args emits `dynamic_bulk_options` and does not prove a known payload.

The engine receives ordinary single-arity `Call` facts. It has no bulk-specific compatibility rule or arity-set type.

## 4. Setter schedules

For Setter `perform_in` and `perform_at`, the first outer call argument is the schedule and is excluded from payload arity. Setter options are not payload arguments. Existing Setter `perform_async` behavior is unchanged.

## 5. Static Client payloads

`push` requires one static Hash payload with runtime-valid string `"class"` and `"args"` keys. `"args"` must be a static Array with no splat; its length is the payload arity. Additional valid string job options do not affect arity.

`push_bulk` uses the same class extraction and bulk normalization for `"args"`. The documented symbol forms of `at`, `batch_size`, and `spread_interval` are accepted because Sidekiq consumes them before normalizing job keys; other non-string keys are unsupported.

A class constant uses the existing root/qualified/lexical worker resolution. A class String must be a canonical Ruby constant path accepted by the supported Prism parser, without leading `::`, and is matched exactly against the base/head worker union. Surrounding namespaces are never prefixed, and Unicode identifiers are not normalized. Both Client APIs share this validation: safely convert the value to valid UTF-8, parse exactly one static constant expression, reuse constant-path extraction, and require the extracted canonical name to equal the complete String value. Malformed bytes, parser diagnostics, whitespace, comments, extra statements, and other non-canonical syntax produce `unsupported_client_payload` JC007 evidence rather than an internal error.

For `"class"` and `"args"` independently, the last Hash entry capable of writing that key determines certainty. A later explicit string key replaces earlier writes; a later unknown Hash splat or dynamic/non-static key makes that key uncertain. Static unrelated keys cannot overwrite it. Parentheses around a single static expression preserve its evidence. Unsupported static non-string keys retain the payload policy above.

A known worker target is retained when only args are uncertain, so JC005 and worker-attributed JC007 can coexist. If class is uncertain, an earlier explicit worker is not retained and cannot create a class-presence request or JC005. A dynamic key that prevents proving either relevant value emits `unsupported_client_payload`; a dynamic key before both final explicit keys does not discard their known evidence.

## 6. Producer uncertainty reasons

Schema v2 adds these deterministic reasons:

- `dynamic_bulk_arguments`;
- `dynamic_bulk_options`;
- `dynamic_client_payload`;
- `dynamic_client_class`;
- `dynamic_client_args`;
- `unsupported_client_payload`.

Recognized but unprovable producer evidence maps to JC007. Known and unknown evidence from one bulk expression may coexist, as may ERROR and WARNING findings. Revision is excluded from the semantic evidence fingerprint exactly as in v0.1.

## 7. Determinism and limits

Facts sharing one path/line/column are totally ordered by method, arity, and uncertainty reason. Producer arity arrays remain sorted unique integers; finding `payload_arity` remains an integer or null. No source is evaluated, required, or booted; there is no local-variable dataflow, Redis access, Sidekiq runtime dependency, checkout, or working-tree mutation.

The Prism constraint remains `>= 1.9, < 2`, and Ruby remains `>= 3.3`.
