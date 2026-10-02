# jobcompat v0.2.1 release notes

jobcompat v0.2.1 is a maintenance release. It makes `.jobcompat.yml` suppressions accept exactly the canonical worker names that producer analysis can report, so a worker that jobcompat can find is also a worker you can suppress. It adds no producer API, compatibility rule, or configuration key.

## Highlights

- `ignore[].worker` accepts canonical Unicode worker names, including names with combining marks such as `ÁJob` and qualified names such as `Admin::ÁJob`.
- Client String worker targets and `ignore[].worker` now use one shared Prism-based canonical worker-name check, so the two can no longer disagree.
- Worker names keep their exact codepoints. jobcompat performs no Unicode normalization.
- Malformed, non-constant, and invalid-byte `ignore[].worker` values are reported as configuration errors (exit 2).

## Unicode suppression consistency

In v0.2.0, producer analysis could report a finding for a worker whose name contains a combining mark, but `.jobcompat.yml` rejected a suppression for that same name with `ignore[0].worker is invalid`. v0.2.1 fixes this. For example, with a worker named `A` + `U+0301 COMBINING ACUTE ACCENT` + `Job` (displayed as `ÁJob`):

```yaml
version: 1

ignore:
  - rule: JC003
    worker: ÁJob
    reason: intentional migration
```

suppresses the matching JC003 finding, exits 0, and keeps the usual suppression audit record (rule, exact worker, reason, finding count) in text and JSON output.

Matching remains exact. jobcompat applies no NFC, NFD, NFKC, or NFKD normalization and no case folding. `ÁJob` written as the single codepoint `U+00C1` followed by `Job` and `ÁJob` written as `A` + `U+0301` + `Job` look the same but are different worker identities: a suppression for one does not suppress a finding for the other. Write the suppression with the same codepoints as the worker name in your source.

## Configuration compatibility note

**An existing v0.2.0 configuration can now fail with exit 2.**

v0.2.0's configuration validator accepted some `ignore[].worker` strings that Ruby does not treat as constant names. Producer analysis can never report such a name, so those entries could never match a jobcompat finding and were silent no-op suppressions. v0.2.1 rejects them as configuration errors (`ignore[N].worker is invalid`, JSON `status: "failed"`, exit 2) instead of ignoring them.

For example, `管理::輸出` is rejected because neither segment starts with an uppercase letter, so Ruby parses it as method calls rather than a constant path. This does not mean CJK worker names are unsupported: `Job管理::E輸出` is a valid Ruby constant path and remains accepted, and analysis and suppression treat it like any other worker name.

## Contracts unchanged

- JC001–JC007 meanings, severities, and precedence are unchanged.
- JSON output remains `schema_version: 2`.
- `.jobcompat.yml` remains `version: 1`.
- Exit codes are unchanged: 0 for no unsuppressed compatibility errors, 1 for compatibility errors, and 2 for tool, config, Git, parser, or usage failures.
- Ruby `>= 3.3` and Prism `>= 1.9, < 2` remain required.

No JSON or configuration schema migration is required.

## Known limitations

ActiveJob, keyword compatibility, payload value types, Hash internal schemas, live Redis inspection, wrappers, aliases, general dataflow, and runtime metaprogramming remain outside scope. An undiscovered producer does not prove that a queue is empty. Analysis does not execute application code. See the [normative v0.2.1 delta](spec-v0.2.1.md) for the full canonical worker-name rules.

## Upgrade notes

If your `ignore[].worker` entries are ordinary Ruby constant names, such as `ExportJob` or `Admin::ExportJob`, no configuration change is needed.

If an `ignore[].worker` entry is a string that is not a canonical Ruby constant name, v0.2.1 reports a configuration error and exits 2. That entry never suppressed anything in v0.2.0. Remove it, or correct it to the exact worker name that jobcompat reports in its findings.

## Installation

After publication, install this version with `gem install jobcompat --version 0.2.1`. Bundler users can specify `gem "jobcompat", "~> 0.2.1", require: false`.

Fetch the intended comparison ref, then run `jobcompat check --base origin/main` or `bundle exec jobcompat check --base origin/main` in the application repository.
