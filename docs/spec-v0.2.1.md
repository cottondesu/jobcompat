# jobcompat v0.2.1 normative delta specification

Status: normative for `0.2.1`

This document is a small delta from [`spec-v0.2.md`](spec-v0.2.md), which remains the normative `0.2.0` delta from [`spec-v0.1.md`](spec-v0.1.md). **All v0.1 and v0.2 rules remain normative unless explicitly overridden here.** v0.2.1 is a maintenance release: it adds no producer syntax, rule, finding field, uncertainty reason, or configuration key.

## 1. Versioned contracts

- Gem and CLI version: `0.2.1`.
- JSON `schema_version`: `2` (unchanged).
- `.jobcompat.yml` version: `1` (unchanged; `version: 2` remains a config error).

No user migration is required.

## 2. Canonical worker-name validation

A canonical String worker name is a String that:

1. converts safely to valid UTF-8;
2. parses with the supported Prism (`>= 1.9, < 2`) without diagnostics;
3. contains exactly one expression;
4. is a static `ConstantReadNode` or `ConstantPathNode` chain, not root-qualified with a leading `::`;
5. when flattened and joined with `::`, equals the complete String exactly.

Prism is the only grammar authority; jobcompat defines no handwritten identifier, case, combining-mark, or Unicode-range rules. Input is never trimmed. Whitespace, comments, newlines, parentheses, calls, operators, extra statements, `self::`, and any other syntax make the String non-canonical.

One internal validator applies this definition to both Client class Strings (`Sidekiq::Client.push` / `push_bulk`) and `.jobcompat.yml` `ignore[].worker`.

**Invariant:** any worker name accepted as an exact canonical String worker name by producer analysis MUST also be valid as `.jobcompat.yml` `ignore[].worker`, subject to the same canonical textual identity rules. Conversely, a configured worker name that producer analysis could not accept as a canonical String is invalid configuration.

Constant AST resolution (for example `"class" => ExportJob`, `ExportJob.perform_async`, and worker declarations) is unchanged and is not governed by this section.

## 3. Suppression semantics

Matching remains exact on `rule_id` plus the worker String. There is no Unicode normalization (no NFC, NFD, NFKC, or NFKD), case folding, namespace inference, partial, glob, or regex matching. Configured names are stored and reported exactly as written.

Visually similar but codepoint-distinct valid names remain different worker identities. For example, `ÁJob` written as `U+00C1 J o b` and as `U+0041 U+0301 J o b` are distinct: a suppression for one does not suppress a finding for the other, and the two entries are not duplicates of each other. Two entries with the same rule and exactly the same worker String remain a duplicate-entry config error.

A qualified name such as `Admin::ÁJob` suppresses only the finding whose worker is exactly that qualified name; `ÁJob` alone does not match it.

A matched suppression keeps the existing audit record (`rule_id`, exact `worker`, `reason`, `finding_count`) in JSON and text output, and a suppressed compatibility ERROR no longer contributes to exit 1.

## 4. Invalid worker-name behavior

The shared validator only decides validity. Each caller owns its failure surface:

- **Config:** a non-canonical, non-String, or invalid-encoding `ignore[].worker` is a `config_error` with the existing message `ignore[N].worker is invalid`, JSON `status: "failed"`, and exit 2. A document whose bytes Psych rejects before validation is also a `config_error` with exit 2. No raw `ArgumentError` or `EncodingError`, `internal_error`, or stack trace is produced.
- **Producer analysis:** a non-canonical or invalid-encoding Client class String remains `unsupported_client_payload` JC007 evidence, as in v0.2.0.

Inside the validator only expected encoding failures are treated as unsupported input; unexpected parser or implementation failures stay visible as tool failures.

Compatibility note: v0.2.0 also accepted some configured names that Ruby does not parse as constants, such as `管理::輸出` (segments that do not start with an uppercase letter). No finding could ever carry such a worker name, so those entries never suppressed anything; v0.2.1 reports them as `config_error`.

## 5. Compatibility invariants

- JC001–JC007 semantics, severities, and precedence are unchanged; there is no JC008.
- Exit codes are unchanged: 0 no unsuppressed compatibility ERROR, 1 compatibility ERROR, 2 tool/config/Git/parser/usage failure.
- JSON schema 2 structure and `unknown_reason` vocabulary are unchanged.
- Runtime dependencies remain `prism >= 1.9, < 2`; Ruby `>= 3.3`.
- Validation parses text only: no eval, `const_get`, constantize, application `require`, Rails or Sidekiq boot, Redis, source execution, or analysis-time network.
- Output remains byte-deterministic, including exact Unicode codepoints.

## 6. Non-goals

New Sidekiq producer APIs, SARIF, ActiveJob, keyword compatibility, payload type or Hash schema checking, Redis inspection, wrapper tracking, aliases, inheritance analysis, general dataflow, feature-flag analysis, new suppression syntax, wildcard suppressions, and regex suppressions.
