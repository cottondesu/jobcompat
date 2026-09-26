# jobcompat

Catch Sidekiq job argument changes that break queued jobs before deploy.

```diff
-def perform(user_id)
+def perform(user_id, format)
```

```text
ERROR JC001 ExportJob
  Base emits 1 argument, but the HEAD worker accepts 2.
  Risk: Jobs queued by the base revision may fail after deployment.
```

No schemas. No annotations. No committed snapshots. No Redis connection. No Rails boot. jobcompat compares existing Ruby source across Git commits.

Your API has a schema. Your database has migrations. What protects your queued jobs?

## Problem

A Sidekiq producer can enqueue arguments today that a different worker version executes later. Changing `perform` can break jobs retained in queues, retry sets, or scheduled sets, and a rolling deploy can run old and new processes together.

## Why this happens

Sidekiq persists a worker `class` and an `args` array. The worker receives those positional arguments through `perform(*args)`. A source change to the method's accepted arity can make a previously valid array invalid.

## Installation

Ruby 3.3 or newer is required. Install with `gem install jobcompat`, or add `gem "jobcompat", require: false` to your Gemfile, run `bundle install`, and use `bundle exec jobcompat`. `prism` is the only runtime dependency; jobcompat does not require the Sidekiq gem to inspect source.

## Quick Start

From a Git repository containing native Sidekiq jobs:

```sh
jobcompat check --base origin/main
jobcompat check --base v0.1.0 --head HEAD --format json
```

Both refs resolve to commits. Staged and uncommitted changes are ignored. The command never checks out another revision or changes the working tree.

## Example output

For a base one-argument producer and a HEAD worker that requires two arguments, text output includes:

```text
ERROR JC001 ExportJob
  Base emits 1 argument, but the HEAD worker accepts 2.
  Revisions: base, head
  Affected directions:
    base producer -> HEAD consumer
    HEAD producer -> HEAD consumer
  Risk: Jobs queued by the base revision may fail after deployment.
```

The second direction appears only when HEAD also has a one-argument producer. Output includes source locations, suggested migration steps, resolved commit SHAs, and a summary. JSON output uses `schema_version: 1` and includes per-worker compatibility matrices.

## How it works

jobcompat reads committed Ruby blobs through Git, parses each selected file with Prism, groups reopened class fragments by canonical name, discovers direct Sidekiq includes and enqueue calls, then compares positional-arity intervals. Application code is never loaded or executed.

Its separate `DefinedConstantIndex` checks tracked Ruby class declarations and named bindings before declaring a worker class absent. A class that remains in an excluded file or stops using a direct Sidekiq include produces a warning rather than a removal error.

## Compatibility directions

| Direction | Question |
| --- | --- |
| `base_to_head` | Can the new worker execute a payload produced by the base revision? |
| `head_to_base` | Can an old worker execute a payload enqueued by a new application node? |
| `head_to_head` | Does HEAD's own producer match its worker? |

The model assumes rolling deployment with old and new processes potentially overlapping. A discovered callsite is treated as potentially reachable; jobcompat does not evaluate feature flags or deployment sequencing.

## Rules

| Rule | Severity | Meaning |
| --- | --- | --- |
| JC001 | ERROR | Base payload accepted by base worker is rejected by HEAD worker |
| JC002 | ERROR | HEAD payload accepted by HEAD worker is rejected by base worker |
| JC003 | ERROR | HEAD producer and HEAD worker disagree |
| JC004 | ERROR | Base worker class is proven absent from HEAD tracked Ruby source |
| JC005 | ERROR | HEAD enqueues a new worker whose class is proven absent from base source |
| JC006 | WARNING | Contract narrowed without a qualifying producer witness |
| JC007 | WARNING | Visible evidence is unsupported or cannot prove compatibility |

One JC001 can cover both `base_to_head` and `head_to_head`; the same mismatch is not repeated as JC003. The same unsupported source evidence in both revisions is one JC007 finding.

## Configuration and targeted suppression

Create `.jobcompat.yml` at the Git root when defaults are insufficient:

```yaml
version: 1
scan:
  include:
    - "**/*.rb"
  exclude:
    - "vendor/**"
    - "tmp/**"
    - "log/**"
    - "coverage/**"
    - ".bundle/**"
    - "test/**"
    - "spec/**"
    - "features/**"
    - "examples/**"
ignore:
  - rule: JC005
    worker: ExperimentalJob
    reason: "Enqueue starts after deployment completes"
```

Each configured `include` or `exclude` list **replaces** its default list, so copy the defaults you still want. `--config PATH` selects another YAML file; a relative path is resolved from the invocation directory. Unknown keys and unsafe YAML aliases fail with exit 2. An ignore entry must have an exact rule, canonical worker name, and non-blank reason. Matched suppressions appear in text and JSON audit output.

## CI usage

Run `jobcompat check --base origin/main --format json` after fetching the comparison ref in CI. Exit 0 means no unsuppressed compatibility errors (warnings may exist), exit 1 means one or more errors, and exit 2 means the analysis could not complete because of CLI, config, Git, parse, or tool failure. A warning never becomes a pass claim for the affected evidence.

## Supported Sidekiq patterns

Direct `include Sidekiq::Job` and legacy `include Sidekiq::Worker` are recognized in top-level and supported namespaced classes. Reopened fragments may split the include and `perform` across files. The producer forms are `Job.perform_async(...)`, `Job.perform_in(schedule, ...)`, `Job.perform_at(time, ...)`, and `Job.set(...).perform_async(...)`. Hash and Array expressions each count as one payload argument. A splat or forwarded producer argument makes arity unknown.

Positional `perform` parameters may be required, optional, rest, post-rest, or forwarding. Keyword parameters make the worker contract unknown for v0.1.

## Limitations and v0.1 non-goals

v0.1 checks **positional arity only**. It does not check value types, Hash internals, keyword compatibility, or JSON serialization. It supports native Sidekiq, not ActiveJob. Only direct includes and the documented direct producer calls are analyzed. `Sidekiq::Client.push`, bulk APIs, wrappers, aliases, inheritance, concerns, arbitrary metaprogramming, feature flags, and general Ruby class/module or superclass conflict analysis are outside scope.

No repository producer callsite does **not** prove an empty queue: queued, scheduled, retried, historical, and external jobs may exist. JC004 requires a completed static absence proof across tracked `.rb` source. An excluded or unrecognized declaration warns. JC005 is a structural rolling-deploy error conditional on an old Sidekiq process being able to consume the new job's queue. Queue isolation and feature flags are not analyzed. Dynamic source may warn or be missed. Working-tree edits are ignored.

## Why not just tests, Sorbet, or Sidekiq strict arguments?

Tests usually run one revision at a time. Sorbet and Sidekiq's strict argument checking address different contracts, such as types or JSON-safe values. jobcompat checks source-derived positional arity across committed revisions and rolling deployment directions. It complements those tools.

## Deployment assumptions and staged migration

For a new argument, first deploy a worker that accepts it optionally, without producing it:

```ruby
def perform(user_id, format = nil)
end
```

After old workers have left the fleet, begin enqueueing `format`. Make the argument required only after jobs with the old shape can no longer be retained or retried. If an external rollout gate makes a reported risk impossible, use a targeted suppression with its reason.

## Security and offline-friendly characteristics

Analysis reads local Git objects only. It does not connect to Redis, boot Rails, load application code, invoke Git hooks, or upload source. Git commands use argv arguments and resolved immutable commit SHAs. It needs no network once Ruby dependencies and Git objects are available.

## Roadmap

Possible future work includes additional native Sidekiq producer APIs and SARIF output. Other frameworks would be considered only after v0.1 usage evidence; they are not supported now.

## Contributing

Run `bundle exec rake test` and `gem build jobcompat.gemspec` with Ruby 3.3 or newer. Tests create temporary Git repositories and need no Redis or Sidekiq server. See [the normative v0.1 spec](docs/spec-v0.1.md) before changing rule behavior.

## License

MIT. See [LICENSE](LICENSE).
