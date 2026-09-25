# jobcompat v0.1 formal specification

Status: frozen implementation-ready specification
Specification date: 2026-09-23
Target release: `0.1.0`

The key words **MUST**, **MUST NOT**, **SHOULD**, and **MAY** are normative.

## 1. Product definition

`jobcompat` is an offline-friendly command-line static analyzer for detecting positional-arity breaking changes in queued native Sidekiq jobs between two Git revisions.

One-line pitch:

> Breaking-change detector for queued background jobs.

Precise v0.1 positioning:

> A Git-aware static compatibility check for native Sidekiq job arity across rolling deployments.

The analyzer treats a background job as an asynchronous contract between:

- a **producer**, which persists a class name and positional payload arguments; and
- a **consumer**, the job class's instance `perform` method, which may run later or on a different deployed revision.

## 2. Goals

v0.1 MUST:

1. compare an explicit base Git ref with a head Git ref (default `HEAD`);
2. leave the index and working tree unchanged;
3. discover direct native Sidekiq job classes from Ruby ASTs;
4. discover supported native Sidekiq enqueue calls from Ruby ASTs;
5. model positional `perform` arity exactly as an integer interval;
6. evaluate base producer → head consumer, head producer → base consumer, and head producer → head consumer;
7. report proven incompatibilities as errors and incomplete proof as warnings;
8. provide deterministic text and stable JSON output;
9. run without Rails boot, application execution, Redis, or a Sidekiq process;
10. be suitable for a CI merge gate.

## 3. Non-goals

The following are explicitly out of scope for v0.1:

- ActiveJob, BullMQ, Celery, SQS, Cloudflare Queues, Resque, GoodJob, and Solid Queue;
- live Redis inspection or reading actual queued/retry/scheduled/dead jobs;
- Rails boot, Bundler application loading, autoloading, or executing repository code;
- `Sidekiq::Client.push`, `push_bulk`, `perform_bulk`, `bulk_perform_async`, or custom wrappers;
- queue rename/migration analysis;
- Hash-internal schemas, required/optional Hash keys, or nested payload structure;
- value types, JSON-serialization safety, Sorbet, RBS, or RBI compatibility;
- keyword-parameter compatibility for `perform`;
- arbitrary metaprogramming, generated methods, `define_method`, or `class_eval`;
- inheritance-, concern-, prepend-, extend-, or alias-based Sidekiq job discovery;
- arbitrary constant lookup, runtime aliases, dependency injection, or feature-flag evaluation;
- inter-procedural data flow, variable value propagation, or call graph construction;
- rename inference or automatic mapping between old and new worker names;
- repository working-tree changes as an analysis snapshot;
- SARIF, GitHub annotations, autofix, or an `init` command.

Absence from source evidence MUST NOT be represented as proof that a queue is empty. The static class-presence proof below concerns tracked Ruby declarations, not runtime constant loading or Redis contents.

## 4. Runtime and supported target

| Item | v0.1 decision |
| --- | --- |
| Implementation | Ruby gem and Ruby CLI |
| Required Ruby | `>= 3.3` |
| Parser | native Prism AST, runtime dependency `prism >= 1.9, < 2` |
| Framework target | native Sidekiq source patterns only |
| Job modules | `Sidekiq::Job`, plus legacy `Sidekiq::Worker` |
| Deployment model | rolling deployment with base and head processes potentially coexisting |
| Analysis | static, whole-snapshot, offline after dependencies and Git objects exist |
| OSS license | MIT, copyright `2026 jobcompat contributors` |

Ruby 3.2 is not selected even though current Sidekiq 8 accepts it, because Ruby 3.2 reached EOL on 2026-04-01. Ruby 3.3 is in security maintenance and Prism is a default gem in Ruby 3.3+. The explicit Prism dependency supplies a consistent supported API across Ruby 3.3, 3.4, and 4.x.

`sidekiq` MUST NOT be a jobcompat runtime dependency. Source recognition does not require loading Sidekiq.

## 5. Snapshot semantics

The command compares two committed snapshots:

- `base`: required user-supplied ref;
- `head`: `HEAD` unless explicitly supplied.

Both refs MUST resolve to commits using the equivalent of:

```text
git rev-parse --verify --end-of-options <ref>^{commit}
```

All subsequent reads MUST use the resolved full commit SHA, not the mutable ref string. Uncommitted and staged changes are intentionally ignored. The text and JSON output MUST include both requested refs and resolved SHAs.

The analyzer MUST NOT run `checkout`, `switch`, `reset`, `stash`, or any command that changes repository state.

## 6. Source selection

A Git blob is scanned when all conditions hold:

1. its tree mode is a regular file (`100644` or `100755`);
2. its repository-relative path matches at least one `scan.include` glob;
3. it matches no `scan.exclude` glob.

Paths use `/` separators, are relative to the Git root, and are matched case-sensitively. Exclude wins over include. Symlinks, submodules, and non-blob entries MUST be skipped.

Glob matching uses `File.fnmatch?` with `File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH` after path normalization. `FNM_CASEFOLD`/`FNM_SYSCASE` are not used. Thus `**/*.rb` includes a root-level Ruby file and Ruby files below dot-directories unless an exclude removes them; `*` never crosses `/`.

Default globs:

```yaml
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
```

Test/example directories are excluded by default because calls there do not prove production enqueue capability. A configured `include` or `exclude` array replaces that default array; it does not append. The README MUST warn users to copy any defaults they still want when overriding.

The normal scan selects workers and producers. The presence-only pass in §7.5 is separate: a class moved to a tracked `.rb` file outside these globs MUST NOT be reported as removed solely because the normal scan no longer selects it.

## 7. Worker discovery

### 7.1 Supported declarations

The analyzer MUST recognize exact constant arguments to a direct `include` call inside a class body:

```ruby
class ExportJob
  include Sidekiq::Job
end
```

```ruby
module Admin
  class ExportJob
    include Sidekiq::Job
  end
end
```

```ruby
class Admin::ExportJob
  include Sidekiq::Job
end
```

```ruby
class ExportWorker
  include Sidekiq::Worker
end
```

Root-qualified constants and parentheses MUST also work:

```ruby
include(::Sidekiq::Job)
```

If an `include` call has multiple arguments, a class is a worker when any argument is exactly `Sidekiq::Job`, `::Sidekiq::Job`, `Sidekiq::Worker`, or `::Sidekiq::Worker`.

### 7.2 Canonical names

Canonical worker names contain no leading `::`:

```text
ExportJob
Admin::ExportJob
```

For nested single-segment `module`/`class` syntax, lexical names are joined with `::`. A root-qualified explicit class path is exact. An unrooted multi-segment class/module path such as `class Admin::ExportJob` is supported only at top level; inside another lexical module it is unsupported because Ruby constant lookup could select either a lexical or top-level prefix. A constant path whose parent is not a static constant path is also unsupported.

### 7.3 Reopened classes

Class fragments with the same canonical name in one revision MUST be grouped. A worker contract is known when:

- at least one fragment directly includes a recognized Sidekiq module; and
- exactly one direct instance `def perform` exists across all fragments.

This permits one file to include Sidekiq and another to define `perform`. Zero or multiple direct `perform` definitions produce JC007 because inheritance, generation, and load order cannot be proven safely.

Fragments are merged by canonical class name within each snapshot, independent of file path and traversal order. Moving or renaming only the include fragment or only the `perform` fragment does not remove the worker when both remain selected. A known contract records every relevant fragment location. In v0.1, a supported worker-contract fragment conflict is limited to directly recognized class fragments of the same canonical Sidekiq worker whose merged direct `perform` definitions cannot yield one deterministic positional contract. Multiple direct `perform` definitions use the existing `multiple_perform_definitions` JC007 reason; zero direct definitions use `missing_perform`. Neither case proves class removal or permits JC004.

This fragment-merge rule does not reconcile general Ruby class/module kind, superclass, constant, autoload, reassignment, or runtime load-order conflicts. Such a conflict alone does not create a new JC007 reason or finding, and its omission does not prove runtime safety, general compatibility, or class deletion. Other unsupported consumer syntax continues to use the existing reasons in §8.3.

### 7.4 Explicit limitations

The following MUST NOT cause worker recognition:

```ruby
class ExportJob < ApplicationJob       # inheritance
end

class ExportJob
  include SidekiqConcern               # indirect concern
end

ExportJob.include(Sidekiq::Job)        # external mutation

ExportJob = Class.new do               # dynamic class
  include Sidekiq::Job
end
```

An unsupported static class/module path whose body directly includes `Sidekiq::Job` or `Sidekiq::Worker` MUST yield JC007 with `worker: null`; jobcompat knows it is intended as a worker but cannot prove its canonical name. Other unsupported class patterns MAY yield JC007 only when they can be associated with an otherwise recognized worker. The analyzer MUST NOT invent a worker name from arbitrary metaprogramming.

### 7.5 DefinedConstantIndex and removal proof

Each snapshot has a lightweight `DefinedConstantIndex`, separate from worker recognition. It records canonical names of statically declared Ruby classes/modules, their locations, and whether each declaration came from the normal scan or a presence-only pass. It also records statically named constant assignments and ambiguous class/module paths as possible bindings. Indexing uses Prism on Git blobs; it MUST NOT execute application code or infer arbitrary runtime aliases. A module or possible binding with the candidate name blocks proof that the name disappeared, even though it does not establish a supported worker.

The index has five query outcomes for a canonical name: `recognized_worker`, `defined_unrecognized`, `outside_scan_scope`, `absent`, or `unverified`; `recognized_worker` is supplied by worker discovery, while the other outcomes come from the index. `defined_unrecognized` means a selected class/module or possible binding exists but a supported worker contract is not recognized. `outside_scan_scope` means an exact declaration or possible binding is in tracked Ruby outside normal scan selection. `absent` means the complete presence check found no exact or plausible declaration/binding. `unverified` means the pass could not exclude one because of an ambiguous path, parse/encoding failure, or resource budget. Both `defined_unrecognized` and `outside_scan_scope` are presence evidence, not proof of a runnable Sidekiq worker.

Presence checking is lazy for names that would otherwise trigger JC004 or JC005. A head-only class without a head enqueue needs no base presence query and is displayed as `not_checked`; it produces no JC005. Reuse selected-file ASTs. For remaining regular tracked paths ending in `.rb` (case-sensitive), regardless of configured include/exclude, stream raw bytes in path order and look for the candidate leaf constant token; only blobs containing it need Prism parsing. A static declaration or named binding of that class cannot omit its literal leaf token. For a non-ASCII candidate leaf, skip the byte prefilter and parse all unselected tracked `.rb` blobs within the same budget; if the pass cannot finish, return `unverified`. The byte prefilter is solely an optimization; it cannot itself prove presence. The pass scans at most 64 MiB (67,108,864 bytes) of unselected Ruby blob bytes per snapshot, counting each path's full blob size. If the next blob would exceed the limit before all are checked, remaining candidates become `unverified`, not `absent`. For an unselected blob with a candidate leaf token, a Prism parse/encoding error or ambiguous canonical path likewise yields `unverified` for affected candidates, without turning an excluded file into a global parse error. Selected-file parse errors still exit 2. The loader streams data and does not keep the excluded tree in memory.

`absent` is a proof only within this static tracked-`.rb` declaration/binding model. Dynamic `const_set`, autoload, code outside tracked `.rb` files, and runtime reassignment are outside v0.1; they are not claimed to be absent at runtime. If the index cannot complete its defined static proof, the corresponding structural rule MUST NOT emit ERROR. A missing recognized worker with `defined_unrecognized`, `outside_scan_scope`, or `unverified` yields one JC007 for that transition, with the relevant source location when available and the base/head worker declaration as supporting evidence. No ordinary finding is emitted merely because a non-worker class exists outside scan scope.

### 7.6 File moves and canonical names

| Change between base and head | Required result |
| --- | --- |
| `app/jobs/export_job.rb` becomes `app/workers/export_job.rb`, canonical name and contract unchanged | no finding; file paths alone are not identities |
| include or `perform` fragment of a reopened class moves or one fragment file is renamed, while all fragments remain selected | merge by canonical name; unchanged contract yields no finding |
| `ExportJob` becomes `GenerateExportJob`, old name proven absent from head tracked `.rb` | JC004 for old name; do not infer a rename relation |
| newly named worker also has head enqueue and its name is proven absent in base tracked `.rb` | conditional-risk JC005 for new name in addition to JC004 |
| old canonical class remains in tracked head `.rb` outside normal scan scope | JC007 `outside_analysis_scope`, never JC004 |

These are snapshot-level rules. No Git rename detection is required: each revision is indexed independently, and paths are evidence locations rather than worker identity.

## 8. Worker contract model

### 8.1 Mathematical model

For a known worker contract, accepted positional arities form an interval:

```text
A = { n ∈ ℕ₀ | min_arity ≤ n ≤ max_arity }
```

If `max_arity` is unbounded:

```text
A = { n ∈ ℕ₀ | min_arity ≤ n }
```

Internal and JSON representation uses `max_arity: null` for positive infinity. `variadic` is true exactly when `max_arity` is null.

Examples:

| Signature | Accepted set | Model |
| --- | --- | --- |
| `def perform` | `{0}` | min 0, max 0 |
| `def perform(user_id)` | `{1}` | min 1, max 1 |
| `def perform(user_id, format = nil)` | `{1,2}` | min 1, max 2 |
| `def perform(a, b = nil, c = nil)` | `{1,2,3}` | min 1, max 3 |
| `def perform(user_id, *args)` | `{1,2,3,...}` | min 1, max null |
| `def perform(*args)` | `{0,1,2,...}` | min 0, max null |
| `def perform(a, *rest, z)` | `{2,3,4,...}` | min 2, max null |
| `def perform(...)` | `{0,1,2,...}` | min 0, max null, signature kind `forwarding` |
| `def perform(a, ...)` | `{1,2,3,...}` | min 1, max null, signature kind `forwarding` |

Required destructured positional parameters count as one positional argument. A block parameter (`&block`) does not change positional arity.

Parameter names are not contract elements. This change is compatible:

```diff
-def perform(user_id)
+def perform(account_id)
```

### 8.2 Prism parameter calculation

For a `Prism::ParametersNode` with no unsupported keywords:

```text
required_count = requireds.length + posts.length
optional_count = optionals.length
min_arity      = required_count
max_arity      = rest ? null : required_count + optional_count
```

`parameters == nil` means `[0,0]`. `RestParameterNode` makes max unbounded. A `ForwardingParameterNode` makes max unbounded while retaining leading required positional parameters.

### 8.3 Unsupported consumer signatures

Any of these make the worker contract unknown and MUST lead to coalesced JC007 warnings rather than a compatibility pass:

- required keyword parameters;
- optional keyword parameters;
- named keyword rest (`**kwargs`);
- `**nil`;
- multiple `perform` definitions;
- no direct `perform` definition;
- a parameter node shape not covered by this specification.

The serialized consumer `unknown_reason` values are fixed for schema v1:

```text
missing_perform
multiple_perform_definitions
keyword_parameters
unsupported_parameters
```

`def perform(...)` is supported because the outer method accepts any positional payload count. jobcompat does not analyze whether its body forwards those arguments into a narrower downstream method.

## 9. Producer discovery

### 9.1 Supported calls

The following direct calls MUST be recognized:

```ruby
ExportJob.perform_async(user_id)
ExportJob.perform_in(5.minutes, user_id)
ExportJob.perform_at(time, user_id)
ExportJob.set(queue: :critical).perform_async(user_id)
```

Supported receiver constants include top-level, qualified, and root-qualified forms.

### 9.2 Payload arity

For `perform_async`, every syntactic argument is one payload argument unless any splat/forwarding argument makes the count unknown.

For `perform_in` and `perform_at`, the first argument is the scheduling argument and MUST be excluded. Therefore:

```ruby
ExportJob.perform_in(5.minutes, user_id, "csv")
```

emits payload arity 2.

An Array literal, Hash literal, or keyword-style Hash is one positional payload element:

```ruby
Job.perform_async(id, { "format" => "csv" }) # arity 2
Job.perform_async([id, other_id])              # arity 1
Job.perform_async                              # arity 0
```

Jobcompat does not decide whether values or Hash keys are JSON-safe; Sidekiq's own strict argument checking owns that concern.

### 9.3 Constant receiver resolution

Producer extraction is two-stage:

1. collect the syntactic receiver and lexical namespace without guessing;
2. resolve it against the union of recognized base/head worker names.

Resolution rules:

- `::Admin::ExportJob` resolves exactly to `Admin::ExportJob`;
- any unrooted static receiver, whether `ExportJob` or `Admin::ExportJob`, tries syntactic lexical prefixes from innermost to outermost and then the receiver as written at top level; it selects the first name present in the worker-name union;
- zero matches means the call is ignored when the receiver is a static constant not known as a worker;
- more than one equally valid result, a non-constant path parent, safe navigation, or a dynamic receiver is unknown.

This is bounded lexical resolution, not general Ruby constant evaluation. Aliases, ancestors, `const_get`, autoload behavior, and runtime reassignments are out of scope.

The base/head union permits a head call to a worker that existed only in base to remain attributable, and permits JC005 to attribute a new head worker.

### 9.4 Unknown producer arity and receiver

Any argument list containing `SplatNode` or `ForwardingArgumentsNode` has unknown payload arity:

```ruby
Job.perform_async(*args)
Job.perform_async(...)
```

No attempt is made to evaluate literal splats in v0.1.

`perform_in`/`perform_at` with no schedule argument or with a splat that prevents separating schedule from payload is unknown.

Calls to target method names on dynamic receivers are visible unknowns:

```ruby
job_class.perform_async(id)
factory.job.perform_at(time, id)
```

They produce JC007 with `worker: null`. This can include non-Sidekiq APIs; it is a warning, never an error. v0.1 suppression requires a worker name, so such findings are controlled through scan exclusions rather than a broad ignore.

`send`, `public_send`, `Sidekiq::Client.push`, wrapper methods, aliases, and inter-procedural calls are not discovered and do not generate warnings.

The serialized producer/call `unknown_reason` values are fixed for schema v1:

```text
splat_arguments
forwarded_arguments
missing_schedule_argument
dynamic_receiver
unsupported_constant_path
safe_navigation_receiver
```

If more than one reason applies to one call, choose the first applicable value in the order shown. An unsupported consumer uses the consumer reason list instead. These strings drive JC007 aggregation and are serialized as `findings[].unknown_reason`; consumer reasons also appear on unknown contract objects.

### 9.5 `.set` chain

v0.1 recognizes exactly an outer `perform_async` whose receiver is an inner `set(...)` call whose receiver resolves to a worker constant. The options passed to `set` do not affect payload arity. Additional chaining and `set(...).perform_in/perform_at` are out of scope for v0.1.

## 10. Compatibility semantics

### 10.1 Directions

The engine MUST evaluate:

| ID | Direction | Purpose |
| --- | --- | --- |
| A | `base_to_head` | old or already queued payload handled by the new worker |
| B | `head_to_base` | new application node's payload handled by an old worker during rolling deploy |
| C | `head_to_head` | current source tree's producer/consumer consistency |

`base_to_base` MAY be calculated as baseline context in JSON matrices, but MUST NOT produce a v0.1 finding by itself.

Every finding has a non-empty `directions` array. Its only values and canonical order are `base_to_head`, `head_to_base`, `head_to_head`; repeated directions are removed. A finding can cover multiple directions when the same proof is owned by one rule. `revisions` is a separate non-empty array of revisions participating in the finding's proof, ordered `base`, then `head`; it does not replace the revision on each proof location. For JC007 specifically, it is the union of snapshots containing the matched root unknown evidence; supporting locations do not add a revision to that array.

### 10.2 Membership

For a known producer arity `P` and consumer acceptance interval `A`:

```text
compatible(P, A) ⇔ P ∈ A
```

### 10.3 Contract inclusion

A base consumer contract is not narrowed when:

```text
A_base ⊆ A_head
```

For intervals, this is true exactly when:

```text
head.min_arity <= base.min_arity
and
(
  head.max_arity is unbounded
  or
  (base.max_arity is finite and base.max_arity <= head.max_arity)
)
```

### 10.4 Matrix status

Each producer/consumer cell is one of:

- `pass`: at least one known call and all known arities are accepted, with no unknown calls;
- `fail`: at least one known call arity is rejected;
- `unknown`: no known rejection, but at least one relevant call or consumer contract is unknown;
- `not_applicable`: there are no relevant producer calls or a consumer is statically proven absent and the cell cannot represent a membership check. A present-but-unrecognized or unverified consumer with relevant producers is `unknown`, never `pass` or `not_applicable`.

Precedence is `fail > unknown > pass > not_applicable`.

### 10.5 No pre-existing-error promotion

JC001 and JC002 MUST identify a compatibility regression, not merely repeat a mismatch already present in the baseline/current tree:

- JC001 requires the base worker to accept the base producer arity and the head worker to reject it.
- JC002 requires the head worker to accept the head producer arity and the base worker to reject it.
- A head producer rejected by the head worker is owned by JC001 when the same `(worker, P)` has a qualifying base producer; otherwise JC003 owns it, even if base also rejects it.

## 11. Rule catalog

Rule IDs are public API. Their meanings MUST NOT be repurposed after 0.1.0. Wording may improve without changing detection semantics.

### JC001 — Old payload rejected by new worker

- **Severity:** error
- **Directions:** `base_to_head`, plus `head_to_head` when a head producer of the same `(worker, P)` is also rejected by the same head contract.
- **Problem:** A known base producer payload that was valid for the base worker is invalid for the head worker.
- **Preconditions:** worker exists with known contracts in base and head; a base enqueue call has known arity `P`; `P ∈ A_base`; `P ∉ A_head`.
- **Exact algorithm:** for every base known enqueue call grouped by worker, test membership in both contracts. Emit one finding per distinct `(worker, P)` and aggregate all base producer locations with that arity. If head also enqueues `P` and the same head contract rejects it, add `head_to_head` and all such head producer locations to this JC001; do not emit JC003 for `(worker, P)`. Do not emit if JC004 owns the worker removal.
- **Unsafe example:** base `perform(id)` and base `perform_async(id)`; head `perform(id, format)`.
- **Safe example:** head `perform(id, format = nil)`.
- **Remediation:** make the new worker accept the old payload; deploy it; only later narrow after queue/retry/scheduled retention is safely handled.
- **False positives:** a discovered base callsite may be unreachable or may never have run; deployment policy may guarantee drained queues.
- **False negatives:** calls through wrappers, `Sidekiq::Client.push`, bulk APIs, dynamic constants, or older queued arities absent from the base snapshot.
- **Suppression:** exact `rule: JC001` + canonical `worker`, with non-empty reason. All aggregated JC001 findings for that worker are suppressed.

### JC002 — New payload rejected by old worker

- **Severity:** error
- **Directions:** `head_to_base`.
- **Problem:** A known head producer emits a payload accepted by the head worker but rejected by the base worker.
- **Preconditions:** worker exists with known contracts in base and head; head enqueue has known `P`; `P ∈ A_head`; `P ∉ A_base`.
- **Exact algorithm:** evaluate each distinct head arity against both contracts. Emit one finding per `(worker, P)`, aggregating producer locations. If head also rejects `P`, ownership belongs to JC001 when that `(worker, P)` has a qualifying base producer, otherwise JC003. If the base class is proven absent, JC005 owns the case; if base presence is unverified or a class/binding remains, emit JC007 instead of an absent-class error.
- **Unsafe example:** base `perform(id)`; head `perform(id, format = nil)` plus head `perform_async(id, "csv")`.
- **Safe example:** release M adds optional consumer argument only; release M+1 starts producing it after old workers are gone.
- **Remediation:** split consumer broadening and producer use across deployments, or gate enqueue activation until the old fleet cannot consume jobs.
- **False positives:** a feature flag or deployment orchestrator may prove the head call cannot execute during overlap.
- **False negatives:** unsupported producers, aliases, wrappers, or deployment overlap longer than the selected base/head pair.
- **Suppression:** exact rule+worker with mandatory reason; intended for externally proven rollout gates.

### JC003 — Current producer/consumer mismatch

- **Severity:** error
- **Directions:** `head_to_head` only when the same `(worker, P)` is not already in JC001.
- **Problem:** A known head producer arity is rejected by its known head worker.
- **Preconditions:** head worker exists with known contract; head enqueue has known `P`; `P ∉ A_head`.
- **Exact algorithm:** group head calls by `(worker, P)` and emit once with all callsites only when JC001 does not already own that worker and arity. It takes precedence over JC002 for the same producer evidence.
- **Unsafe example:** head `perform(id)` and `perform_async(id, "csv")`.
- **Safe example:** head `perform(id, format = nil)` with one- or two-argument calls.
- **Remediation:** align enqueue arity with `perform` before merge.
- **False positives:** a callsite may be unreachable, monkey-patched, or invoke a different runtime constant.
- **False negatives:** unsupported wrappers and dynamic dispatch.
- **Suppression:** exact rule+worker; use sparingly because this is a same-revision mismatch.

### JC004 — Worker class absent from HEAD source

- **Severity:** error
- **Directions:** `base_to_head`.
- **Problem:** A canonical supported Sidekiq worker in base has no corresponding class/module declaration or statically named binding in HEAD's tracked `.rb` source under the defined static presence model. Queues, retries, and scheduled jobs may retain its serialized old class name.
- **Preconditions:** worker recognized in base; no supported head worker of that name; HEAD `DefinedConstantIndex` returns `absent` after the complete presence-only pass.
- **Exact algorithm:** take `workers_base.keys - workers_head.keys`, then query HEAD presence for each candidate. Emit once per name only for `absent`. For `defined_unrecognized`, `outside_scan_scope`, or `unverified`, emit JC007 instead. JC004 owns the proven absent head consumer, so do not synthesize JC001 or JC003 for that absence. Attach any head callsites still targeting the absent worker as supporting locations.
- **Unsafe example:** delete or rename `ExportJob` in one release.
- **Safe example:** retain `ExportJob` as a delegating compatibility shell until the retention window is over, then remove it in a later release.
- **Remediation:** use a staged removal/rename and preserve an old class entry point long enough for queued, retry, and scheduled jobs.
- **False positives:** an operator may have authoritatively drained all relevant Redis sets and disabled all old producers; dynamically defined or externally loaded runtime constants are outside the static source model.
- **False negatives:** indirect/inherited workers not recognized in base.
- **Suppression:** exact rule+worker with a reason documenting the drain/retention guarantee.

JC004 is an error because the previously recognized serialized class name has been proven absent from HEAD's tracked `.rb` declarations/bindings within the defined static model. It does not claim that an old job definitely exists in Redis. Losing worker recognition alone never qualifies.

### JC005 — New worker enqueued before old fleet can understand it

- **Severity:** error
- **Directions:** `head_to_base`.
- **Problem:** head introduces a supported worker and a known head producer can enqueue it while the base class is statically proven absent. If an old Sidekiq process can consume that job during the rolling deployment, it cannot resolve the new worker class; production failure is conditional on that assignment.
- **Preconditions:** worker absent from recognized base workers, present in head, at least one head enqueue call has a statically resolved target name matching it, and base `DefinedConstantIndex` returns `absent`. Payload arity may be known or unknown because the old class is absent either way.
- **Exact algorithm:** for each `workers_head.keys - workers_base.keys`, find all attributable head enqueue calls and query base presence. Emit one finding per worker aggregating all calls only if presence is `absent`. Do not emit for a new worker with no discovered head enqueue. If base presence is `defined_unrecognized`, `outside_scan_scope`, or `unverified`, use JC007, not an absent-class ERROR. If a call's payload arity is unknown, JC005 owns `head_to_base`; JC007 may still report that `head_to_head` compatibility is unproven.
- **Unsafe example:** add `GenerateReportJob` and immediately call `GenerateReportJob.perform_async(id)` in the same rolling release.
- **Safe example:** deploy the worker class first; begin enqueueing in a later release, or use an externally controlled post-deploy gate.
- **Remediation:** separate class availability from producer activation.
- **False positives:** queue isolation, an old fleet that does not consume that queue, a feature flag that delays enqueue activation, or other deployment sequencing may prevent old-process consumption. v0.1 does not evaluate these controls.
- **False negatives:** dynamic/wrapper enqueue calls or workers delivered outside the analyzed repository.
- **Suppression:** exact rule+worker with mandatory rollout-gate reason; it can document externally proven queue or deployment controls.

### JC006 — Worker contract narrowed without sufficient producer evidence

- **Severity:** warning
- **Directions:** `base_to_head`.
- **Problem:** the head worker no longer accepts the full base arity set, but known base callsites do not prove that a removed arity was produced. No repository producer callsite found does not prove that no queued, scheduled, retried, historical, or externally enqueued payload exists. The head interval may also add other arities; it need not be a strict subset of the base interval.
- **Preconditions:** known worker contracts exist in base and head; `A_base ⊄ A_head`; no known base producer `P` satisfies `P ∈ A_base` and `P ∉ A_head`; no JC003 head producer has `P ∈ A_base` and `P ∉ A_head`; worker is not removed.
- **Exact algorithm:** perform interval inclusion once per worker after JC001/JC003 evidence ownership. Emit one worker-level warning and describe `A_base ∖ A_head` as one or two removed integer ranges. Unknown base producers do not turn this into an error.
- **Unsafe example:** base `perform(id, format = nil)` becomes head `perform(id)` with no two-argument base callsite found.
- **Safe example:** base `perform(id)` becomes head `perform(id, format = nil)`, which broadens the contract.
- **Remediation:** retain the broader signature until the maximum queue/retry/schedule lifetime has elapsed, or document and suppress a proven drain.
- **False positives:** the removed arity may never have been used and no such job may remain.
- **False negatives:** a contract can remain arity-compatible while becoming semantically or type-incompatible.
- **Suppression:** exact rule+worker with reason.

### JC007 — Compatibility could not be proven

- **Severity:** warning
- **Directions:** derived from the unknown evidence as defined below.
- **Problem:** visible source evidence cannot be reduced to a known worker name, producer arity, or consumer interval.
- **Preconditions:** one of the explicitly unsupported/unknown visible cases occurs: splat/forwarded enqueue arguments, dynamic receiver on a target enqueue method, unsupported `perform` keywords, zero/multiple `perform` definitions, malformed scheduled call, unsupported static constant path, or a class-presence transition that is `defined_unrecognized`, `outside_scan_scope`, or `unverified`.
- **Exact algorithm:** create one finding per semantic root unknown evidence fingerprint (§12), coalescing affected directions and revisions. A base producer unknown affects `base_to_head`; a head producer unknown affects `head_to_base` and `head_to_head`; an unknown base consumer affects `head_to_base`; an unknown head consumer affects `base_to_head` and `head_to_head`. A head class-presence uncertainty replacing a base worker affects `base_to_head`; the symmetric base uncertainty for a new head worker and head enqueue affects `head_to_base`. The same semantic root present in both snapshots is one finding with the union in canonical order. Do not emit one warning per downstream rule. A parser syntax error in a selected file is a tool error with exit 2; uncertainty from an unselected presence-only file is JC007.
- **Unsafe example:** `ExportJob.perform_async(*args)` or `def perform(id:)`.
- **Safe example:** explicit producer arguments with a positional `def perform(id, options = {})`.
- **Remediation:** use supported explicit syntax, exclude non-production code, or accept the warning while recognizing that compatibility is unproven.
- **False positives:** dynamic `perform_async` methods may belong to a non-Sidekiq API; forwarded `perform` may be operationally safe.
- **False negatives:** metaprogrammed calls that do not expose a target method name in the AST.
- **Suppression:** exact rule+worker works only when a worker is known. Worker-less dynamic warnings are controlled by scan exclusions in v0.1.

## 12. Finding de-duplication and precedence

Rules are evaluated in this order for ownership, not presentation:

1. JC004 worker removal;
2. JC005 new worker activation;
3. JC001 old-to-new regression, absorbing the same worker/arity's head-to-head mismatch;
4. JC003 remaining current mismatch;
5. JC002 new-to-old rollout regression;
6. JC006 unproven narrowing;
7. JC007 unknown evidence.

Requirements:

- JC004 suppresses JC001 for the same missing head consumer.
- JC005 suppresses JC002 for the same absent base consumer.
- JC004 and JC005 require an `absent` result from the opposite revision's `DefinedConstantIndex`; worker-set difference alone is insufficient.
- JC001 owns both `base_to_head` and `head_to_head` for the same worker, payload arity, and head consumer contract when qualifying base and head producer evidence exists. Its `revisions`, `directions`, and proof locations are unions. JC003 MUST NOT also report that worker/arity.
- JC003 owns a head-to-head mismatch only when JC001 does not own the same worker/arity.
- JC003 suppresses JC002 for the same head call and arity.
- Identical rule/worker/arity evidence is aggregated into one finding with multiple locations. The aggregation key MUST NOT include `directions`, because direction union happens after evidence ownership.
- JC006 is not emitted when JC001 already proves a removed accepted arity for that worker.
- JC006 is not emitted when JC003 already proves, for the same worker, a current head call using an arity accepted by base but removed by head.
- JC007 is coalesced by semantic root evidence across base/head and may coexist with JC006 when the roots represent different facts. A JC004/JC005 presence uncertainty creates one JC007 for that transition; do not separately warn once per file inspected.

### 12.1 JC007 semantic evidence fingerprint

The fingerprint excludes revision and source line/column. It is the tuple:

```text
[
  uncertainty_kind,
  unknown_reason,
  canonical_worker_name_or_null,
  sorted_repository_relative_source_paths,
  lexical_enclosing_class_module_and_method_chain,
  normalized_root_expression_and_enclosing_statement,
  occurrence_group_size,
  occurrence_ordinal
]
```

`uncertainty_kind` is one of `producer_arity`, `producer_receiver`, `consumer_contract`, `worker_identity`, `class_presence`. The reason uses the fixed enum for producer, consumer, or presence uncertainty. The lexical chain records syntactic class/module segments and method name/kind, including an explicit anonymous/unsupported marker where a canonical name cannot be established. For a multi-fragment consumer uncertainty, the root is the class's aggregate contract fact: paths and normalized expressions of all relevant direct include/`perform` fragments are sorted, and all fragment locations are retained. A missing `perform` uses the recognized include fragment(s) as its root. For class-presence uncertainty, the root is the observed declaration/binding when one exists; `unverified` uses the candidate worker name plus the deterministic blocking file/budget identity.

Normalize only the syntax that causes uncertainty as an ordered sequence of Prism token kind and token bytes, omitting whitespace and comments. For producer uncertainty, use the target enqueue call; for consumer uncertainty, use the `def perform` header/parameter list, not the method body; for worker identity, use the declaration path and relevant include; for presence uncertainty, use the observed declaration/binding or a synthetic `presence_unverified` marker plus the blocking path or budget boundary. Preserve identifiers, literal bytes, punctuation, and child order. Include the smallest enclosing statement's normalized token sequence for producer calls so identical calls in different statements remain distinct. This is conservative syntax equivalence, not Ruby evaluation: a changed relevant token may leave two findings even when runtime meaning is equal. That is preferable to merging different causes. Unrelated method-body edits do not change a signature fingerprint.

Within each revision and each tuple prefix through the normalized expression, sort roots by source byte offset and assign `occurrence_ordinal` from 1. Include the group's size in the fingerprint. Thus two identical expressions in one scope are always separate findings. Cross-revision pairing is allowed only for exact fingerprint equality and one-to-one ordinal correspondence; changed multiplicity or uncertain pairing leaves separate findings. Matched roots yield one JC007 with unioned `revisions`, `directions`, and deduplicated, revision-tagged locations. The primary display location is the first sorted location. An unchanged selected blob at the same path therefore yields one warning, not one per revision.

Every finding MUST carry all locations needed to audit its proof, not only the producer locations:

| Rule | Required location roles |
| --- | --- |
| JC001 | base producer, base consumer, head consumer; head producer too when `head_to_head` is included |
| JC002 | head producer, head consumer, base consumer |
| JC003 | head producer, head consumer |
| JC004 | base worker declaration and consumer when present; head producer calls still targeting the absent name when present |
| JC005 | head worker declaration and head producer |
| JC006 | base and head consumers |
| JC007 | every matched root unsupported call, signature, worker fragment, or presence-blocking declaration; base/head supporting worker declarations when presence is unverified |

## 13. False-positive policy

The normative policy is:

```text
ERROR   = a structural incompatibility is proven under the documented
          rolling-deployment and callsite-reachability assumptions.

WARNING = risk or incomplete analysis exists, but incompatibility cannot
          be fully proven from supported source evidence.
```

For ERROR rules, “proven” means that the supported AST contains the relevant worker/call contracts and the set/range relation fails. It does not prove that a branch executes, a feature flag is enabled, or a matching job currently exists in Redis. Those are declared deployment assumptions and suppression responsibilities.

For JC004 and JC005, “proven” additionally requires completed static class-presence absence in the opposite snapshot. A present or unverified class is JC007, never an absent-class ERROR. JC005's old-process failure is conditional on that process being able to consume the new job from its queue during overlap. Queue isolation and deployment sequencing are not analyzed.

Unknown MUST never be converted to compatible. This is the product principle:

> Absence of proof is not proof of compatibility.

## 14. CLI

### 14.1 Commands

```text
jobcompat check --base REF [options]
jobcompat --help
jobcompat --version
jobcompat check --help
```

`init` is not included. Defaults are usable without configuration, and generating one small YAML file does not justify another command in v0.1.

### 14.2 `check` options

```text
--base REF          required; base commit-ish
--head REF          optional; default HEAD
--format FORMAT     text (default) or json
--config PATH       optional; default <git-root>/.jobcompat.yml when present
-h, --help          command help
```

No `--strict`, `--verbose`, color control, output-file option, or SARIF option exists in v0.1. Warnings always exit 0. Text output contains no ANSI color, making terminals and CI logs deterministic.

A relative `--config` path is resolved against the invocation directory. The default config path is resolved at the Git root. Missing explicitly requested config is exit 2; absent default config is valid and uses defaults.

### 14.3 Streams

- help/version: stdout;
- completed text or JSON analysis: stdout;
- CLI usage errors before a format is established: stderr;
- text-mode tool/config/git/parser errors: stderr;
- JSON-mode tool/config/git/parser errors after option parsing: a JSON failure envelope on stdout; unexpected crash details remain on stderr without a backtrace unless a future debug mode is added.

## 15. Text output

Text output MUST lead with the comparison and summary, then list findings in deterministic order. Example:

```text
jobcompat 0.1.0
Comparing origin/main (a1b2c3d) -> HEAD (d4e5f6a)
Deployment model: rolling

ERROR JC002 ExportJob
  New payload is not accepted by the previous worker.

  Revisions: base, head
  Affected directions:
    HEAD producer -> base consumer
  Base worker: perform(user_id) accepts 1
  HEAD worker: perform(user_id, format = nil) accepts 1..2
  HEAD producer: ExportJob.perform_async(user_id, "csv") emits 2

  Risk: During a rolling deploy, a new application node can enqueue this
  payload before all Sidekiq workers have been upgraded.

  base app/jobs/export_job.rb:4 (consumer)
  head app/jobs/export_job.rb:4 (consumer)
  head app/services/exporter.rb:21 (producer)

  Suggested migration:
    1. Deploy the optional worker argument without using it.
    2. Start enqueueing the new argument in a later release.

Summary: 1 error, 0 warnings, 0 suppressed
```

A shared old/current payload failure renders as one JC001, not an additional JC003:

```text
ERROR JC001 ExportJob
  Base and HEAD producers emit 1 argument; the HEAD worker requires 2.
  Revisions: base, head
  Affected directions:
    base producer -> HEAD consumer
    HEAD producer -> HEAD consumer
```

An unchanged unsupported call in both snapshots renders once:

```text
WARNING JC007 ExportJob
  Revisions: base, head
  Reason: splat_arguments (producer payload arity is unknown)
  Affected directions:
    base producer -> HEAD consumer
    HEAD producer -> base consumer
    HEAD producer -> HEAD consumer
```

JC005 risk text MUST say: `If an old Sidekiq process can consume this job during the rolling deployment, it cannot resolve the new worker class.` It MUST NOT say production execution will inevitably fail. JC006 text MUST state that no repository producer callsite found does not prove that no queued, scheduled, retried, historical, or externally enqueued payload exists. These explanations appear inside the relevant finding, not as a warning on every otherwise passing worker.

No findings:

```text
jobcompat 0.1.0
Comparing origin/main (a1b2c3d) -> HEAD (d4e5f6a)
Deployment model: rolling

PASS: no compatibility errors or warnings found.
Summary: 0 errors, 0 warnings, 0 suppressed
```

Warnings without errors use `PASS WITH WARNINGS` and exit 0.

When suppressions match, text output adds a compact block before the summary, one line per matched `(rule, worker)` in rule/worker order:

```text
Suppressed findings:
  JC005 ExperimentalJob (1): Enqueue activation occurs only after the worker rollout completes

Summary: 0 errors, 0 warnings, 1 suppressed
```

## 16. JSON output schema v1

### 16.1 Evolution policy

- `schema_version` is integer `1` for v0.1.
- Removing a field, changing a field's type/meaning, or changing an enum incompatibly requires a schema-version increment.
- New optional fields may be added within schema version 1. Consumers MUST ignore unknown fields.
- All documented fields are always present; unavailable values use `null`, not omission, except future additive fields.
- JSON is UTF-8, pretty-printed with two-space indentation, contains unescaped Unicode where the JSON library permits it, and ends with exactly one newline.

### 16.2 Completed example

```json
{
  "schema_version": 1,
  "tool": { "name": "jobcompat", "version": "0.1.0" },
  "status": "completed",
  "comparison": {
    "deployment_model": "rolling",
    "base": { "ref": "origin/main", "sha": "a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4a1b2c3d4" },
    "head": { "ref": "HEAD", "sha": "d4e5f6a7d4e5f6a7d4e5f6a7d4e5f6a7d4e5f6a7" }
  },
  "configuration": { "path": ".jobcompat.yml" },
  "findings": [
    {
      "rule_id": "JC002",
      "title": "New payload rejected by old worker",
      "severity": "error",
      "worker": "ExportJob",
      "revisions": ["base", "head"],
      "directions": ["head_to_base"],
      "unknown_reason": null,
      "message": "HEAD emits 2 arguments, but the base worker accepts 1.",
      "risk": "A new producer can enqueue work that an old worker cannot execute during a rolling deploy.",
      "remediation": [
        "Deploy the optional worker argument first.",
        "Start enqueueing the new argument in a later release."
      ],
      "payload_arity": 2,
      "locations": [
        { "revision": "base", "path": "app/jobs/export_job.rb", "line": 4, "column": 3, "role": "consumer" },
        { "revision": "head", "path": "app/jobs/export_job.rb", "line": 4, "column": 3, "role": "consumer" },
        { "revision": "head", "path": "app/services/exporter.rb", "line": 21, "column": 5, "role": "producer" }
      ]
    }
  ],
  "suppressions": [],
  "workers": [
    {
      "name": "ExportJob",
      "base_presence": "recognized_worker",
      "head_presence": "recognized_worker",
      "base_contract": { "status": "known", "min_arity": 1, "max_arity": 1, "variadic": false, "signature_kind": "positional", "signature": "perform(user_id)", "unknown_reason": null },
      "head_contract": { "status": "known", "min_arity": 1, "max_arity": 2, "variadic": false, "signature_kind": "positional", "signature": "perform(user_id, format = nil)", "unknown_reason": null },
      "producer_arities": {
        "base": [1],
        "head": [1, 2],
        "base_unknown_calls": 0,
        "head_unknown_calls": 0
      },
      "compatibility": {
        "base_to_base": "pass",
        "base_to_head": "pass",
        "head_to_base": "fail",
        "head_to_head": "pass"
      }
    }
  ],
  "diagnostics": [],
  "summary": {
    "errors": 1,
    "warnings": 0,
    "suppressed": 0,
    "files_scanned": { "base": 42, "head": 43 },
    "workers": { "base": 8, "head": 8 },
    "enqueue_calls": { "base": 21, "head": 22, "unknown": 0 }
  }
}
```

The `directions` array also lets one JC001 carry `base_to_head` and `head_to_head`. For an unchanged `ExportJob.perform_async(*args)` root in both snapshots, the completed finding has `"rule_id": "JC007"`, `"revisions": ["base", "head"]`, `"directions": ["base_to_head", "head_to_base", "head_to_head"]`, `"unknown_reason": "splat_arguments"`, and both revision-tagged locations; it counts as one warning.

### 16.3 Failure example

```json
{
  "schema_version": 1,
  "tool": { "name": "jobcompat", "version": "0.1.0" },
  "status": "failed",
  "comparison": {
    "deployment_model": "rolling",
    "base": { "ref": "missing-ref", "sha": null },
    "head": { "ref": "HEAD", "sha": null }
  },
  "configuration": { "path": null },
  "findings": [],
  "suppressions": [],
  "workers": [],
  "diagnostics": [
    {
      "category": "git_error",
      "message": "Base ref 'missing-ref' does not resolve to a commit.",
      "location": null
    }
  ],
  "summary": null
}
```

### 16.4 Field definitions

| Field | Type | Meaning |
| --- | --- | --- |
| `schema_version` | integer | output contract version |
| `tool` | object | stable `name` (`jobcompat`) and semantic `version` strings |
| `status` | `completed` or `failed` | whether analysis completed |
| `comparison.deployment_model` | `rolling` | fixed v0.1 deployment model |
| `comparison.base/head.ref` | string | user-requested ref |
| `comparison.base/head.sha` | string or null | resolved full commit SHA; null only when resolution did not complete |
| `configuration.path` | string or null | loaded config display path; null when defaults were used or config loading did not complete |
| `findings` | array | unsuppressed rule findings; empty on failed analysis |
| `findings[].rule_id` | `JC001` through `JC007` | stable rule identifier |
| `findings[].title` | string | stable rule title from the catalog |
| `findings[].severity` | `error` or `warning` | severity before suppression |
| `findings[].worker` | string or null | canonical name; null for unattributed dynamic or unsupported-path evidence |
| `findings[].revisions` | non-empty array | participating proof revisions in `base`, `head` order; for JC007, snapshots containing the matched root evidence |
| `findings[].directions` | non-empty array | unique subset in `base_to_head`, `head_to_base`, `head_to_head` order; JC001 can have two |
| `findings[].unknown_reason` | string or null | fixed producer/consumer/presence reason for JC007, null for other rules |
| `findings[].message` | string | concise fact-specific explanation |
| `findings[].risk` | string | deployment consequence |
| `findings[].remediation` | non-empty array of strings | ordered corrective steps |
| `findings[].payload_arity` | non-negative integer or null | known evidence arity, otherwise null |
| `findings[].locations` | non-empty array | proof locations required by the rule table above |
| finding location | object | `revision`, repository-relative `path`, 1-based `line`, 1-based byte `column`, and `role` |
| `suppressions` | array | matched targeted suppressions, empty when none or on failed analysis |
| `suppressions[].rule_id/worker/reason` | strings | exact configured suppression identity and mandatory rationale |
| `suppressions[].finding_count` | positive integer | number of findings omitted by that suppression |
| `workers` | array | one entry for each canonical name in the base/head worker union, sorted by name |
| `workers[].name` | string | canonical worker name without leading `::` |
| `workers[].base_presence/head_presence` | presence enum | `recognized_worker`, `defined_unrecognized`, `outside_scan_scope`, `absent`, `unverified`, or `not_checked`; the last means no absence-dependent rule needed a query |
| `workers[].base_contract/head_contract` | contract object or null | null means no recognized worker contract in that revision; use presence status to distinguish proven absence from unrecognized/out-of-scope/unverified class |
| contract `status` | `known` or `unknown` | whether a positional interval was extracted |
| contract `min_arity/max_arity/variadic` | integer/null/boolean or nulls | populated for `known`; `max_arity: null` plus `variadic: true` means unbounded; all three null for `unknown` |
| contract `signature_kind` | `positional`, `forwarding`, or null | null for unknown |
| contract `signature` | string or null | concise source signature; null when unavailable |
| contract `unknown_reason` | string or null | reason enum for unknown; null for known |
| `producer_arities.base/head` | arrays of integers | sorted unique known payload arities |
| `producer_arities.base_unknown_calls/head_unknown_calls` | non-negative integers | visible calls attributable to this worker whose arity is unknown |
| `compatibility.*` | matrix status | one of `pass`, `fail`, `unknown`, `not_applicable` |
| `diagnostics` | array | empty on completed analysis; one or more tool diagnostics on failure |
| `diagnostics[].category` | diagnostic enum | `config_error`, `git_error`, `parse_error`, or `internal_error` |
| `diagnostics[].message` | string | concise sanitized failure explanation |
| `diagnostics[].location` | object or null | optional `revision`, `path`, `line`, and 1-based byte `column`; it has no finding role |
| `summary` | object or null | completed counts, null on failed analysis |
| `summary.errors/warnings/suppressed` | non-negative integers | unsuppressed error/warning counts and matched suppressed-finding count |
| `summary.files_scanned.base/head` | non-negative integers | selected blobs parsed per revision |
| `summary.workers.base/head` | non-negative integers | recognized canonical workers per revision, including unknown contracts |
| `summary.enqueue_calls.base/head/unknown` | non-negative integers | visible target enqueue calls by revision; `unknown` is the cross-revision count with unknown receiver or arity |

`diagnostics[].category` enum: `config_error`, `git_error`, `parse_error`, `internal_error`.

Location `role` enum: `consumer`, `producer`, `worker_declaration`, `unknown_call`. Location `revision` enum: `base`, `head`.

Finding `unknown_reason` uses the producer values in §9.4, consumer values in §8.3, or the presence values `worker_not_recognized`, `outside_analysis_scope`, `presence_unverified`. The latter correspond respectively to `defined_unrecognized`, `outside_scan_scope`, and `unverified`. The public `revisions` and `directions` arrays have the fixed orders from §10.1; no singular `direction` field exists in schema v1.

All arrays and objects are serialized in the key order shown. Although JSON consumers cannot rely on object-key order semantically, exact-output tests enforce deterministic bytes.

For a contract with an unsupported signature, the JSON shape is:

```json
{
  "status": "unknown",
  "min_arity": null,
  "max_arity": null,
  "variadic": null,
  "signature_kind": null,
  "signature": "perform(id:)",
  "unknown_reason": "keyword_parameters"
}
```

`status: "completed"` covers both exit 0 and exit 1; a compatibility finding is a completed analysis, not a tool failure. On `completed`, `diagnostics` is empty and `summary` is non-null. On `failed`, `findings`, `suppressions`, and `workers` are empty, `diagnostics` is non-empty, and `summary` is null.

## 17. Exit codes

| Code | Meaning |
| ---: | --- |
| 0 | analysis completed and no unsuppressed error findings exist; warnings may exist |
| 1 | analysis completed with at least one unsuppressed error finding |
| 2 | CLI, config, Git, parser, I/O, or internal tool failure prevented a trustworthy complete analysis |

Suppressed errors do not affect the exit code. A parse error in any selected Ruby file is exit 2, not JC007 and not a partial success.

`--strict` is deliberately omitted. A fixed warning policy keeps CI semantics simple for v0.1.

## 18. Configuration

### 18.1 File

Default file: `.jobcompat.yml` at the Git root. Minimal schema:

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
    reason: "Enqueue activation occurs only after the worker rollout completes"
```

### 18.2 Validation

- top-level keys allowed: `version`, `scan`, `ignore`;
- `version` is required when a config exists and MUST equal integer `1`;
- `scan` keys allowed: `include`, `exclude`;
- omitted `scan` uses both default arrays; omitting only `include` or `exclude` preserves the default for that key;
- `include` is a non-empty array of non-empty glob strings;
- `exclude` is an array of non-empty glob strings and MAY be empty to clear all default exclusions;
- glob strings are repository-relative and MUST NOT start with `/`, contain NUL, or contain a `..` path segment;
- omitted `ignore` means an empty array; an explicit empty array is valid;
- `ignore` is an array of objects with exactly `rule`, `worker`, `reason`;
- rule is one of JC001–JC007;
- worker is a non-empty exact canonical worker name without leading `::`;
- reason is a non-blank string;
- duplicate `(rule, worker)` entries are invalid;
- unknown keys at any level are invalid;
- YAML aliases and arbitrary object deserialization are forbidden;
- invalid config is exit 2.

The implementation MUST use `Psych.safe_load` with no permitted classes or symbols and aliases disabled.

### 18.3 Suppression behavior

Suppressions are applied after findings are constructed and before formatting/exit-code calculation. A suppression matches exact `rule_id` and exact canonical `worker`. It suppresses all findings for that pair, including multiple arities/callsites.

Suppressed findings are omitted from `findings`, but each matched `(rule, worker)` is represented once in the text suppression block and JSON `suppressions` array with its configured reason and `finding_count`. The summary `suppressed` value is the sum of those counts. Unmatched config entries are not rendered.

There is no global rule disable, wildcard worker, severity customization, expiry, or inline source comment in v0.1. Inline comments are rejected because they couple application source to a young tool, complicate AST/comment association, and encourage broad local silence. The YAML entry gives reviewers one central reasoned exception list.

Unused suppression entries do not fail v0.1 and do not warn; stale-ignore reporting is a roadmap option.

## 19. Determinism

The same Git object database, refs resolved to the same SHAs, config bytes, jobcompat version, Prism major/minor, and Ruby platform MUST produce byte-identical JSON.

Sort order:

1. findings: severity (`error`, then `warning`), rule ID, worker (null last), payload arity (null last), primary path, line, directions, revisions, unknown reason;
2. finding locations: revision (`base`, then `head`), path, line, column, role;
3. suppressions: rule ID, worker;
4. workers: canonical name;
5. producer arity arrays: numeric ascending and unique;
6. diagnostics: category, location path/line, message.

Text uses the same finding order.

## 20. Failure handling and safety

- Source code is read only from local Git objects.
- Source is never uploaded or sent to an external API.
- Redis credentials are neither required nor read.
- Application source is never required, evaluated, or executed.
- Git commands use argv arrays through `Open3`; no shell string or `eval` is allowed.
- User refs are resolved once with `--end-of-options`; resolved SHAs are used afterward.
- Raw blobs are read without textconv, filters, checkout, or hooks.
- Invalid source encoding or Prism parse error is a located parse diagnostic and exit 2.
- Selected files are visited in normalized path order. Parsing continues across selected files only to collect all Prism errors; if any exist, they are sorted by revision/path/line/column, compatibility evaluation is skipped, and JSON uses one failed envelope.
- Expected operational errors MUST not print Ruby backtraces.

Boundary evaluation order is deterministic: parse CLI options, locate Git root, load/validate config, resolve base, resolve head, read/parse snapshots, then evaluate compatibility. Except for parse-error aggregation, the first failed boundary stops the command. Partial ref resolutions already obtained are retained in the failure envelope; SHAs not yet resolved are null.

## 21. Limitations for README

The README MUST state prominently:

- v0.1 checks positional arity only, not value/type/Hash schema compatibility;
- native Sidekiq only; ActiveJob is not supported;
- only direct `include Sidekiq::Job`/`Worker` discovery;
- only documented direct enqueue syntax;
- no live queue knowledge, so queue presence/absence is not proven; absent producer callsites never establish an empty queue;
- JC004 requires a completed static absence proof across tracked `.rb` source; moved/excluded or unrecognized class declarations warn instead;
- JC005 is an ERROR for structural old-fleet inability under the documented rolling model, conditional on old Sidekiq processes being able to consume the queue;
- dynamic/metaprogrammed behavior may warn or be missed;
- feature flags are not evaluated;
- working-tree changes are ignored because refs resolve to commits;
- errors rely on the rolling-deploy assumption that discovered production callsites may execute;
- scan defaults exclude tests/specs/examples and can be configured.

## 22. README v0.1 outline

The implementation session MUST create README sections in this order:

1. `# jobcompat`
2. one-line pitch
3. five-second diff and error, before prose:
   ```diff
   -def perform(user_id)
   +def perform(user_id, format)
   ```
   `ERROR: existing queued jobs may fail after deployment`
4. positioning question: “Your API has a schema. Your database has migrations. What protects your queued jobs?”
5. Problem
6. Why this happens, with persisted `class` + `args`
7. Installation
8. Quick Start (`jobcompat check --base origin/main`)
9. Example output
10. How it works
11. Compatibility directions A/B/C
12. Rules JC001–JC007 summary table
13. Configuration and targeted suppression
14. CI usage, including exit codes
15. Supported Sidekiq patterns
16. Limitations / v0.1 non-goals
17. Why not just tests / Sorbet / Sidekiq strict args?
18. Deployment assumptions and staged migration example
19. Security and offline-friendly characteristics
20. Roadmap: additional Sidekiq producer APIs, SARIF, then other frameworks only after v0.1 evidence
21. Contributing
22. License

The README License section links to `LICENSE` and states MIT. Repository/homepage metadata that requires a future GitHub owner or URL MUST be omitted rather than invented until that external fact exists.

The README MUST not advertise ActiveJob/BullMQ/Celery support as if committed. They may appear only in roadmap language.

## 23. Acceptance criteria

v0.1 is specification-complete when an implementation satisfies all of:

1. no Git working-tree/index mutation;
2. direct Sidekiq job discovery for all three namespace forms and legacy Worker;
3. exact interval arity for zero, required, optional, rest, post, forwarding, and parameter rename;
4. known producer arity for async, scheduled, and `.set(...).perform_async` calls;
5. Hash/Array each count as one argument;
6. splats and unsupported signatures never pass silently;
7. A/B/C directions are separately represented;
8. optional consumer expansion alone is safe;
9. starting to produce the new optional argument yields JC002 against base;
10. a worker class proven absent from HEAD tracked `.rb` declarations yields JC004, while a present or unverified class yields JC007 instead;
11. new worker plus head enqueue yields JC005;
12. narrowing without base producer evidence yields JC006 only;
13. a head-only mismatch yields JC003; when the same worker/arity also qualifies for JC001, one JC001 has both directions and no JC003;
14. config is strict and safe-loaded;
15. exact rule+worker suppression works and requires a reason;
16. JSON conforms to schema version 1 and is deterministic;
17. exits 0/1/2 exactly as specified;
18. invalid selected Ruby source causes exit 2 with location;
19. tests create local temporary Git repositories and need no network;
20. README communicates value in its first screen and accurately lists limitations;
21. identical semantic JC007 roots across snapshots aggregate to one finding with both revisions, while distinct roots remain separate;
22. a file rename or movement of selected reopened fragments with unchanged canonical name and contract yields no finding;
23. a class moved outside normal scan scope but present in tracked `.rb` source does not yield JC004;
24. no repository producer with a narrowed contract yields JC006 without claiming queue emptiness.

## 24. v0.1 specification freeze review

The 2026-09-23 freeze review checked the normative rules against `docs/architecture.md` and `docs/implementation-plan.md`:

| Gate | Result | Contract |
| --- | --- | --- |
| 1. Same JC007 evidence across base/head | pass | revision-free fingerprint pairs one-to-one; `revisions` and directions are unioned |
| 2. JC001/JC003 precedence | pass | qualifying JC001 absorbs the same worker/arity's head-to-head failure; JC003 handles remaining head mismatches |
| 3. Multiple directions per finding | pass | non-empty `directions` array with fixed A/B/C order |
| 4. Class remains but worker recognition fails | pass | presence is `defined_unrecognized`; JC007, never JC004 |
| 5. Class moved outside normal scan scope | pass | presence-only tracked-`.rb` pass yields `outside_scan_scope`; JC007, never JC004 |
| 6. Actual tracked-`.rb` class deletion | pass | complete `absent` proof yields JC004 |
| 7. JC005 conditional risk | pass | proven base absence plus head enqueue; old-fleet failure is conditional on queue consumption |
| 8. Producer absence | pass | JC006 explains why no callsite does not establish an empty queue |
| 9. File rename only | pass | canonical class/contract unchanged means no finding |
| 10. Implementation test coverage | pass | the cross-revision matrix covers dedup, presence safety, class/file moves, reopening, and producer absence |
| 11. ERROR proof standard | pass | JC001–JC003 use known contracts/calls; JC004/JC005 additionally require static absence proof; other uncertainty is WARNING |
| 12. Normative completeness | pass | no open placeholder or undecided v0.1 behavior remains in this specification |
