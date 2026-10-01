# jobcompat v0.2.0 release notes

jobcompat v0.2.0 broadens native Sidekiq producer coverage while preserving JC001–JC007, the three rolling-deployment directions, and positional-arity analysis.

## Highlights

- Recognize worker bulk calls, scheduled and bulk Setter calls, and direct static Sidekiq Client payloads.
- Normalize bulk jobs into distinct arity facts without losing known rows when other rows are unknown.
- Resolve Client Hash evidence independently for `"class"` and `"args"` in source order.
- Validate exact String worker names with Prism's Ruby constant syntax, preserving Unicode spelling and handling malformed names conservatively.
- Emit JSON schema version 2; `.jobcompat.yml` remains version 1.

## New producer coverage

The following forms join the existing `perform_async`, `perform_in`, `perform_at`, and `set(...).perform_async` support:

- `Worker.perform_bulk(...)`;
- `Worker.set(...).perform_in(...)` and `.perform_at(...)`;
- `Worker.set(...).perform_bulk(...)`;
- `Sidekiq::Client.push(...)` and `.push_bulk(...)`.

Setter options and the first schedule argument of `perform_in` / `perform_at` do not count as job payload arguments.

## Bulk behavior

```ruby
ExportJob.perform_bulk([
  [1],
  [2, "csv"]
])
```

This supplies distinct positional arity facts for 1 and 2. Duplicate arities are collapsed, and an empty bulk Array supplies no producer evidence. Dynamic rows or inner splats remain conservative JC007 evidence without discarding known sibling rows. A dynamic outer collection remains unknown. Bulk calls use the existing compatibility rules; findings still carry one integer or null `payload_arity`.

## Sidekiq::Client support

Direct `Sidekiq::Client.push` and `push_bulk` calls accept statically understandable Hash payloads with string `"class"` and `"args"` keys. `push` counts a static args Array; `push_bulk` applies the same bulk normalization as worker calls.

For each relevant key, the last entry capable of writing it determines certainty. Later explicit keys can restore certainty after earlier splats or dynamic keys. Later unknown writes prevent proof of the affected key. A known worker with unknown args can still supply JC005 presence evidence and worker-attributed JC007; an uncertain class is not attributed to an earlier worker.

Class constants use the existing bounded lexical, qualified, and root-qualified resolution. Class Strings are exact canonical Ruby constant paths accepted by Prism, without leading `::`, namespace prefixing, or Unicode normalization. Malformed syntax and invalid String bytes become unsupported JC007 evidence. Payload variables, general Hash evaluation, Client instances, and wrappers are not inferred. See the [normative v0.2 scope](spec-v0.2.md) for supported options and uncertainty reasons.

## JSON schema 2

v0.1 emitted `schema_version: 1`; v0.2 emits `schema_version: 2`. Schema 2 extends producer uncertainty reasons for bulk and Client APIs while preserving the existing output structure, findings, directions, revisions, and locations.

The added reasons are `dynamic_bulk_arguments`, `dynamic_bulk_options`, `dynamic_client_payload`, `dynamic_client_class`, `dynamic_client_args`, and `unsupported_client_payload`.

The `.jobcompat.yml` configuration schema is separate and remains `version: 1`. Do not change it to version 2.

## Compatibility

JC001–JC007 meanings, severity, JC001/JC003 precedence, static-presence proof, and the base-to-head, head-to-base, and head-to-head directions are unchanged. Exit codes remain 0 for no unsuppressed errors, 1 for compatibility errors, and 2 for tool/config/Git/parser/usage failures. Warnings do not establish compatibility for unknown evidence.

## Known limitations

ActiveJob, keyword compatibility, payload value types, Hash internal schemas, live Redis inspection, wrappers, aliases, general dataflow, and runtime metaprogramming remain outside scope. An undiscovered producer does not prove that a queue is empty. Analysis does not execute application code.

The existing suppression worker-name validator is stricter than producer discovery for some Unicode combining-mark identifiers. Such workers can be analyzed correctly but rejected in `.jobcompat.yml` ignore entries. This pre-existing limitation is a v0.2.1 follow-up candidate; it does not affect general Unicode producer recognition.

## Upgrade notes

Update JSON consumers to accept schema version 2 and the additional producer uncertainty reasons. Keep configuration version 1. Broader producer discovery may surface compatibility errors or JC007 warnings that v0.1 did not report; review those findings before deployment.

Ruby 3.3 or newer and Prism `>= 1.9, < 2` remain required. No Sidekiq runtime dependency is added.

## Installation

After publication, install this version with `gem install jobcompat --version 0.2.0`. Bundler users can specify `gem "jobcompat", "~> 0.2.0", require: false`.

Fetch the intended comparison ref, then run `jobcompat check --base origin/main` or `bundle exec jobcompat check --base origin/main` in the application repository.
