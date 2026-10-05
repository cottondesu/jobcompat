# jobcompat v0.3.0 release notes

jobcompat v0.3.0 adds static worker-rename compatibility analysis for native Sidekiq. Supported aliases can keep old serialized worker names resolvable during rolling deployments. The release also models the difference between Sidekiq producers that pass a Class object and Client producers that pass an exact String identity.

## Highlights

- Recognize supported static compatibility aliases such as `OldJob = NewJob`.
- Resolve finite alias chains and supported namespaces conservatively.
- Avoid a false JC004 when a retained old serialized identity still resolves through a safe alias.
- Normalize Class-object producer identities through aliases to their terminal Class names.
- Preserve exact `Sidekiq::Client` String identities.
- Report relevant alias uncertainty as JC007 instead of assuming compatibility.
- Upgrade JSON output to schema version 3 and include alias provenance.

## Safe worker rename compatibility aliases

For a rename, keep a static alias while old payloads may still be retained:

```ruby
class NewExportJob
  include Sidekiq::Job

  def perform(id)
  end
end

OldExportJob = NewExportJob
```

Queued, retried, or scheduled payloads already serialized as `"OldExportJob"` can resolve through this alias to the `NewExportJob` contract. A safe alias can therefore prevent JC004 for `OldExportJob` while those payloads may still run.

An alias does not hide a real argument incompatibility. If the terminal worker no longer accepts an old payload's positional arity, jobcompat can still report JC001 or JC006 under the existing rules.

Supported aliases are unconditional plain constant assignments, including supported namespace forms. Finite chains are resolved; for example, `LegacyExportJob = PreviousExportJob` and `PreviousExportJob = ExportJob` make `ExportJob` the effective consumer. This is a documented static subset, not general Ruby constant or alias resolution.

## Serialized identity: Class objects vs exact Strings

Ruby aliases refer to the same Class object. Given:

```ruby
OldExportJob = NewExportJob
OldExportJob.perform_async(1)
```

the source token is `OldExportJob`, but the value passed to Sidekiq is the `NewExportJob` Class object. Sidekiq serializes that object's canonical name, so jobcompat models the persisted identity as `NewExportJob`. During a rolling deployment, activating this producer can still produce JC005 for `NewExportJob` if the old fleet does not recognize that name.

**Keeping `OldExportJob = NewExportJob` protects retained old `"OldExportJob"` payloads, but calling `OldExportJob.perform_async(...)` is not a mechanism for continuing to enqueue the old serialized class name.**

An explicit Client String has different identity behavior:

```ruby
Sidekiq::Client.push(
  "class" => "OldExportJob",
  "args" => [1]
)
```

Here the serialized identity remains exactly `OldExportJob`; jobcompat models that String as-is and can resolve it through the consumer-side alias. Client String pushes are described to explain identity modeling, not as the default rename strategy; their job-option and default semantics differ.

## Conservative alias uncertainty

jobcompat does not assume compatibility when Ruby behavior is ambiguous. Relevant uncertainty is reported as JC007 with one of these reasons:

- `alias_target_unresolved`: the target cannot be proven to end at a recognized worker.
- `alias_cycle`: aliases refer back to each other.
- `alias_binding_conflict`: the same constant has conflicting definitions or writes.
- `unsupported_alias_assignment`: the assignment is conditional, dynamic, operator-based, or otherwise outside the supported syntax.

Unknown does not mean compatible. jobcompat does not execute application source to resolve these cases. It supports plain static assignments such as `OldJob = NewJob`, supported qualified paths, and supported namespace bodies. It does not resolve `const_set`, `autoload`, `const_missing`, conditional aliases, dynamic right-hand-side evaluation, runtime load order, general Ruby constant evaluation, or heuristic renames.

## JSON schema 3

**v0.3.0 changes JSON `schema_version` from 2 to 3.** `workers[]` now represents compared serialized worker identities and exposes alias provenance. Each worker result includes `base_alias` and `head_alias`; the presence value `resolved_alias` identifies a successfully resolved alias. `summary.workers.base` and `.head` continue to count directly recognized Sidekiq workers, not aliases.

The `.jobcompat.yml` configuration schema remains `version: 1`. Do not change the configuration version to 3.

## Compatibility contracts

No new JC rule was added. JC001–JC007 IDs, severities, JC001/JC003 precedence, the three rolling-deployment directions, exit codes, and suppression identity remain unchanged. The configuration schema remains version 1, Ruby `>= 3.3` remains required, and Prism `>= 1.9, < 2` remains the supported range.

## Upgrade notes

**Consumers that parse jobcompat JSON must update to accept `schema_version: 3` before upgrading to v0.3.0.** Do not assume that a schema 2 consumer can read schema 3 unless that consumer explicitly supports new schema versions and fields.

No `.jobcompat.yml` version change is needed. Keep a compatibility alias for as long as old serialized identities can remain in queues, retries, schedules, or other retained payloads. Plan producer activation separately: calling an aliased Class object's Sidekiq API serializes the terminal Class name.

## Known limitations

Analysis covers positional arity for native Sidekiq workers only. ActiveJob and keyword compatibility are unsupported. jobcompat does not inspect Hash internal schemas, payload value types, live Redis contents, general dataflow, arbitrary Client instances, wrapper inference, runtime load order, or general aliasing and metaprogramming. It does not execute application code.

No repository producer callsite does not prove an empty queue. Queued, scheduled, retried, historical, and external jobs may still exist; static analysis does not establish runtime queue contents.

## Installation

```bash
gem install jobcompat --version 0.3.0
```

Bundler users can add:

```ruby
gem "jobcompat", "~> 0.3.0", require: false
```

Then fetch the comparison ref and run:

```bash
jobcompat check --base origin/main
```

or:

```bash
bundle exec jobcompat check --base origin/main
```
