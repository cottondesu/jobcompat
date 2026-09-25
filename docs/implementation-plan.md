# jobcompat v0.1 implementation plan

Status: executable plan for the next Codex session
Date: 2026-09-23
Scope guard: this document plans implementation; no product implementation was created in the specification session.

## 1. Delivery strategy

Implement in small vertical increments. Every phase ends with an observable command or focused test result. Do not begin multi-framework abstractions, Redis integration, ActiveJob, or schema/type analysis.

Required execution environment:

- Ruby 3.3 or newer (the current machine's system Ruby 2.6 is insufficient and must not be used for implementation validation);
- Git available on PATH;
- no Redis, Rails app, Sidekiq server, or network needed for tests.

Dependency policy:

- runtime: Prism only (`>= 1.9`, `< 2`);
- CLI: `OptionParser`;
- config/output/process: standard `Psych`, `JSON`, `Open3`;
- tests: Minitest and Rake;
- no new dependency without revisiting `docs/architecture.md` and documenting the need.

## 2. Definition of done

The implementation is done only when:

1. every acceptance criterion in `docs/spec-v0.1.md` passes;
2. unit, analysis, integration, CLI, and determinism tests pass on supported Ruby versions;
3. a temporary real Git repository demonstrates exit 0, 1, and 2;
4. text output is inspected as a user would see it;
5. JSON output validates against the documented schema fields and stable fixtures;
6. `git status` of the analyzed fixture proves `jobcompat check` does not mutate it;
7. README's first screen communicates the five-second example;
8. no product code supports out-of-scope frameworks or APIs;
9. packaging builds the gem and the installed executable runs `--help`, `--version`, and `check`;
10. pre-existing or environment-specific test failures are clearly separated from regressions.

## 3. Phase plan

### Phase 0 — toolchain and executable skeleton

**Files**

```text
jobcompat.gemspec
Gemfile
Rakefile
LICENSE
exe/jobcompat
lib/jobcompat.rb
lib/jobcompat/version.rb
lib/jobcompat/cli.rb
lib/jobcompat/errors.rb
test/test_helper.rb
test/integration/check_command_test.rb
```

**Implementation tasks**

- create a conventional gem without generated framework code;
- set `required_ruby_version >= 3.3`;
- add Prism runtime dependency only;
- add Minitest/Rake development dependencies;
- define `Jobcompat::VERSION = "0.1.0"`;
- implement top-level help, version, `check --help`, and structural option validation without pretending analysis completed;
- define typed expected error classes;
- make the executable return integer exit codes through `CLI.start`.

**Tests**

- `jobcompat --help` exits 0 and lists `check`;
- `jobcompat --version` prints exactly `jobcompat 0.1.0` and exits 0;
- `jobcompat check --help` documents base/head/format/config;
- missing `--base` exits 2 with one concise usage error;
- unknown command/option exits 2;
- no ANSI escape sequences appear.

**Completion criteria**

- gem builds locally;
- executable works through `bundle exec` and built-gem installation in a temp directory;
- no analysis behavior is faked as complete.

### Phase 1 — strict configuration

**Files**

```text
lib/jobcompat/config.rb
test/unit/config_test.rb
test/fixtures/config/*.yml   # only if fixture files improve readability
```

**Implementation tasks**

- encode exact default include/exclude arrays;
- load `.jobcompat.yml` via `Psych.safe_load` with aliases/classes/symbols disabled;
- validate schema version, types, keys, rule IDs, canonical worker names, reasons, and duplicate suppressions;
- implement path matching with `FNM_PATHNAME | FNM_EXTGLOB | FNM_DOTMATCH`, explicitly excluding platform case-fold flags;
- implement exact `rule_id + worker` suppression;
- retain a matched suppression audit record with configured reason and suppressed finding count;
- distinguish absent default config from missing explicit config.

**Tests**

- no config produces documented defaults;
- valid minimal and full config;
- include match, exclude match, exclude precedence, root `.rb` file, dot path, nested path;
- user-provided include/exclude replaces the corresponding defaults;
- empty exclude clears default exclusions; empty include is rejected;
- absolute, NUL-containing, and parent-traversal globs are rejected;
- missing explicit config exits/raises config error;
- unknown top-level/nested/ignore key rejected;
- string `"1"` version rejected; version 2 rejected;
- empty include/exclude item rejected;
- invalid rule and leading-`::` worker rejected;
- blank reason rejected;
- duplicate `(rule, worker)` rejected;
- YAML alias/object tag rejected;
- known-worker suppression matches exactly and does not wildcard namespaces.

**Completion criteria**

- Config has no dependency on CLI, Git, AST, or formatters;
- every invalid shape produces a path-specific message such as `ignore[0].reason must be non-blank`.

### Phase 2 — immutable Git snapshot loader

**Files**

```text
lib/jobcompat/git_repository.rb
lib/jobcompat/revision_snapshot.rb
test/support/temporary_repository.rb
test/integration/git_repository_test.rb
```

**Implementation tasks**

- implement a test helper that initializes a temporary repo, writes files, commits, and returns SHAs without network;
- locate the Git root from a nested directory;
- resolve refs with `--verify --end-of-options <ref>^{commit}`;
- enumerate default-format `ls-tree -r -z --full-tree` entries and split each NUL record at its first tab into mode/type/OID and path;
- keep regular tracked `.rb` path/OID metadata for the lazy presence-only pass, while filtering full analysis by config;
- implement the framed `cat-file --batch` reader;
- yield `(path, oid, bytes)` rather than accumulating full source trees;
- expose requested ref, resolved SHA, and files-scanned count;
- use `Open3` argv arrays and `GIT_OPTIONAL_LOCKS=0`.

**Tests**

- branch, tag, abbreviated/full SHA, and `HEAD` resolve to full SHA;
- invalid/missing/non-commit ref becomes `GitError`;
- base and head content differ without checkout;
- staged, unstaged, and untracked files are ignored;
- current branch/index/working-tree bytes and `git status --porcelain` are unchanged after reads;
- root and nested Ruby files read correctly;
- excluded blobs are not yielded;
- executable bit regular blob is included;
- symlink and submodule entries are skipped;
- paths containing spaces, tabs, Unicode, and newlines survive NUL enumeration;
- empty blobs and blobs without trailing newline frame correctly;
- missing/corrupt object or batch process failure is a Git error;
- same OID can be memoized without changing path/revision locations.
- added, deleted, and renamed paths are independently enumerated in each snapshot without diff or rename inference;
- excluded tracked `.rb` blobs remain available by OID for a candidate-only presence check, without entering normal `files_scanned` counts.

**Completion criteria**

- an integration test reads two commits while the user's checkout remains on head with dirty changes intact;
- one tree-list and one batch-content process per snapshot/comparison, not one process per file.

### Phase 3 — source locations and constant-name extraction

**Files**

```text
lib/jobcompat/model/source_location.rb
lib/jobcompat/analysis/constant_name.rb
test/unit/constant_name_test.rb
```

**Implementation tasks**

- define immutable `SourceLocation` with 1-based line/byte-column;
- flatten `ConstantReadNode` and static `ConstantPathNode`;
- retain leading-root qualification;
- reject paths with dynamic parents;
- define lexical candidate generation for an unqualified constant.

**Tests**

- `ExportJob`, `Admin::ExportJob`, `::Admin::ExportJob`;
- nested paths with three segments;
- `self::ExportJob`, `factory::ExportJob`, and call-derived parents are non-static;
- lexical candidates for `Admin::Billing` are ordered `Admin::Billing::ExportJob`, `Admin::ExportJob`, `ExportJob`;
- root-qualified and already qualified names bypass lexical prefixes;
- Unicode constant names preserve bytes and locations;
- columns are converted exactly once from Prism's zero-based value.

**Completion criteria**

- no Ruby constant lookup or source execution occurs;
- constant utility accepts Prism nodes and returns a small value, not strings plus hidden flags.

### Phase 4 — worker discovery and arity model

**Files**

```text
lib/jobcompat/analysis/worker_discovery_visitor.rb
lib/jobcompat/analysis/defined_constant_index.rb
lib/jobcompat/model/worker_contract.rb
lib/jobcompat/analysis/sidekiq_analyzer.rb
test/analysis/worker_discovery_visitor_test.rb
test/unit/worker_contract_test.rb
test/analysis/sidekiq_analyzer_test.rb
```

**Implementation tasks**

- track module/class namespaces;
- collect direct `include` facts and direct instance `perform` definitions;
- group reopened class fragments per revision;
- limit v0.1 fragment conflicts to supported same-canonical Sidekiq worker fragments that cannot yield one deterministic direct positional `perform` contract; use the existing zero/multiple-`perform` reasons, without general Ruby class/module, superclass, constant, or load-order reconciliation;
- index exact/plausible static class/module declarations and statically named bindings separately from supported worker discovery;
- reuse selected-file ASTs for presence facts; lazily stream excluded tracked `.rb` blobs only for potential JC004/JC005 names, byte-prefilter by leaf token, and parse candidate-bearing blobs for presence only;
- cap unselected source bytes inspected at 64 MiB per snapshot; incomplete/ambiguous/invalid excluded source yields `unverified`, never an absence ERROR;
- calculate exact positional intervals;
- create a distinct unknown-contract object/reason;
- use only the fixed schema-v1 consumer unknown-reason enum;
- abort the snapshot on Prism parse errors;
- preserve a concise definition signature and source location.

**Worker-discovery tests**

| Case | Expected |
| --- | --- |
| `include Sidekiq::Job` | discovered |
| `include ::Sidekiq::Job` | discovered |
| `include(Sidekiq::Job)` | discovered |
| multi-argument include containing Sidekiq module | discovered |
| `include Sidekiq::Worker` | discovered legacy worker |
| nested `module Admin; class ExportJob` | `Admin::ExportJob` |
| `class Admin::ExportJob` | `Admin::ExportJob` |
| root-qualified class path | canonical name without leading `::` |
| unrooted multi-segment class path inside another module with direct Sidekiq include | JC007 with null worker, never mis-canonicalized |
| same leaf name in two namespaces | two independent workers |
| plain Ruby class | ignored |
| inherited base job | ignored |
| indirect concern | ignored |
| external `ExportJob.include` | ignored |
| `Class.new` | ignored |
| reopened worker: include and perform in separate files | one known contract |
| move only include fragment or only perform fragment between selected files | same canonical merged contract |
| rename one selected fragment file | same canonical merged contract |
| selected class remains but direct include changes to indirect concern | `defined_unrecognized`; JC007, never JC004 |
| class moves to excluded tracked `.rb` | `outside_scan_scope`; JC007, never JC004 |
| excluded candidate-bearing Ruby fails parse or presence budget exhausts | `unverified`; JC007, never JC004/JC005 |
| zero direct perform | unknown contract |
| two direct perform definitions | unknown duplicate contract |
| same canonical worker with direct `perform` definitions in two supported fragments | JC007 `multiple_perform_definitions` |
| a class/module kind disagreement or different superclass in another fragment | no conflict-specific JC007; existing supported evidence still applies |
| nested worker inside worker class | correct independent contexts |

**Arity tests**

| Signature | Expected |
| --- | --- |
| `def perform; end` | `0..0` |
| one/multiple required positional | exact count |
| one/multiple optional positional | continuous finite interval |
| required + optional | correct min/max |
| rest only | `0..∞` |
| required + rest | `required..∞` |
| required post after rest | min includes post |
| destructured required parameter | counts as one |
| block parameter | ignored for arity |
| name-only rename | equal contracts |
| `def perform(...)` | `0..∞`, forwarding |
| leading args plus forwarding | leading minimum, unbounded max |
| required/optional keyword | unknown |
| named keyword rest / `**nil` | unknown |

**Parse tests**

- valid file with Prism warnings still yields facts; warnings do not enter public findings or completed diagnostics;
- invalid Ruby gives all Prism error locations and no partial contracts;
- parse errors across multiple selected files are aggregated and deterministically sorted;
- source encoding error is a parse/tool error;
- same blob OID analysis reuse does not reuse wrong revision labels.
- a presence-only excluded-file parse failure does not become a global selected-file parse error.

**Completion criteria**

- `WorkerContract#accepts?` and `#superset_of?` pass exhaustive boundary tests;
- AST code contains no compatibility rule IDs.
- a presence-only result distinguishes `absent` from defined, out-of-scope, and unverified without loading application code.

### Phase 5 — producer discovery and name resolution

**Files**

```text
lib/jobcompat/analysis/producer_discovery_visitor.rb
lib/jobcompat/analysis/semantic_evidence.rb
lib/jobcompat/model/enqueue_call.rb
test/analysis/producer_discovery_visitor_test.rb
test/analysis/sidekiq_analyzer_test.rb
```

**Implementation tasks**

- collect unresolved enqueue facts for supported target method names;
- count direct async payload arguments;
- remove the schedule argument for in/at;
- recognize one `.set(...).perform_async` chain;
- detect splat/forwarding/malformed schedule as unknown;
- capture dynamic receiver warnings;
- use only the fixed schema-v1 producer unknown-reason enum and its precedence;
- resolve static receivers only after the base/head worker union exists.
- preserve relevant Prism token sequence, enclosing statement and lexical scope for revision-free JC007 evidence fingerprints; assign deterministic occurrence ordinals within each same-expression group.

**Producer-call tests**

| Call | Expected payload |
| --- | ---: |
| `Job.perform_async(id)` | 1 |
| `Job.perform_async` | 0 |
| `Job.perform_async(id, {"x" => 1})` | 2 |
| `Job.perform_async([id, other])` | 1 |
| `Job.perform_async(id: 1)` | 1 Hash payload; type safety not assessed |
| `Job.perform_in(5, id)` | 1 |
| `Job.perform_in(5, id, "csv")` | 2 |
| `Job.perform_at(time)` | 0 |
| `Job.set(queue: :critical).perform_async(id)` | 1 |
| `Job.perform_async(*args)` | unknown, JC007 fact |
| `Job.perform_async(...)` | unknown, JC007 fact |
| `Job.perform_in(*args)` | unknown schedule/payload split |
| `Job.perform_in` | unknown malformed scheduled call |
| `job_class.perform_async(id)` | dynamic worker, unknown |
| `factory.job.perform_at(time, id)` | dynamic worker, unknown |
| `Job&.perform_async(id)` | unknown safe-navigation receiver |
| `Job.public_send(:perform_async, id)` | ignored |
| `Sidekiq::Client.push(...)` | ignored/out of scope |
| `Job.perform_bulk(...)` | ignored/out of scope |
| `Job.set(...).perform_in(...)` | ignored/out of scope |

**Namespace-resolution tests**

- exact `Admin::ExportJob`;
- root `::Admin::ExportJob`;
- unqualified `ExportJob` inside `Admin` resolves to `Admin::ExportJob` when present;
- qualified `Admin::ExportJob` inside `Tenant` first tries `Tenant::Admin::ExportJob`, then top-level;
- fallback to top-level when namespaced worker absent;
- nested `module A::B` uses exact syntactic lexical scope;
- same leaf in two namespaces resolves by innermost candidate;
- constant receiver not in base/head worker union is ignored;
- head call to base-only removed worker remains attributable;
- head call to head-only new worker resolves;
- dynamic/unsupported parent never guesses.

**Completion criteria**

- producer visitor output is revision-independent unresolved data;
- a call with any splat cannot accidentally receive a numeric arity;
- Hash/Array AST contents are never recursively counted as multiple payload slots.
- repeated identical expressions in one scope retain separate occurrence identities, while an unchanged expression in base/head can pair.

### Phase 6 — pure compatibility matrix

**Files**

```text
lib/jobcompat/model/compatibility_result.rb
lib/jobcompat/compatibility/engine.rb
test/unit/compatibility_engine_test.rb
```

**Implementation tasks**

- group producers by revision/worker;
- compute known unique arities and unknown counts;
- calculate the four matrix cells with `fail > unknown > pass > not_applicable`;
- keep base/base as non-finding baseline context;
- return immutable per-worker results sorted by canonical name.

**Tests**

- no producers -> not applicable;
- all known arities accepted -> pass;
- one of several arities rejected -> fail;
- accepted known call plus unknown call -> unknown;
- rejected call plus unknown call -> fail;
- unknown consumer with producer -> unknown;
- missing consumer status is not silently pass;
- base/head producer sets remain distinct;
- zero-arity producers behave correctly;
- unbounded consumers accept arbitrarily large test arities;
- finite interval boundary inclusions/exclusions;
- matrix exactly reflects the motivating optional-argument scenario.

**Completion criteria**

- no I/O, parser objects, config, or output strings in the engine tests;
- table-driven tests cover every status transition.

### Phase 7 — rules, precedence, aggregation, suppression

**Files**

```text
lib/jobcompat/model/finding.rb
lib/jobcompat/compatibility/rules.rb
lib/jobcompat/compatibility/engine.rb
test/unit/rules_test.rb
test/unit/compatibility_engine_test.rb
```

**Implementation tasks**

- produce pure engine preflight requests for potential JC004/JC005 names; after the CLI resolves opposite-snapshot `DefinedConstantIndex` statuses, emit absence ERROR only for `absent` and JC007 for present/unverified candidates;
- implement JC001 before JC003/JC002; a qualifying JC001 absorbs the same worker/arity's head-to-head mismatch as a second direction and includes both revisions' producer locations;
- implement JC006 interval narrowing;
- map unknown facts/contracts/presence transitions to JC007;
- derive JC007 direction and revision sets from the evidence role, then pair exact revision-free semantic fingerprints one-to-one across snapshots;
- implement evidence ownership and duplicate suppression;
- aggregate producer and consumer proof locations by rule/worker/arity; union directions/revisions without using them as aggregation keys;
- apply targeted config ignores and count suppressed findings;
- derive exit 0/1 after suppression.

**Compatibility scenario tests**

| Base | Head | Expected |
| --- | --- | --- |
| required arg added; base call used old arity | new rejects old | JC001 error |
| optional arg added, producer unchanged | broadening only | no finding |
| optional arg added and head starts 2-arg enqueue | base rejects, head accepts | JC002 error |
| positional arg removed and base producer uses removed arity | head rejects | JC001 error |
| optional becomes required, base has one-arg call | head rejects | JC001 error |
| optional becomes required, no base witness | contract narrowed | JC006 warning |
| finite interval narrows at max with no witness | narrowing | JC006 warning |
| worker declaration actually deleted from tracked `.rb` source | head presence proven absent | JC004 only |
| worker canonical class renamed in one change | old name proven absent; new name proven absent in base | JC004 plus conditional JC005 only when new enqueue exists |
| file renamed, canonical class/contract unchanged | both snapshots recognize same worker | no finding |
| worker moved to another selected file | same canonical worker | no finding |
| class moved outside normal scan scope to tracked `.rb` | head presence outside scan | JC007, not JC004 |
| direct Sidekiq include becomes indirect concern but class remains | head class defined, worker unrecognized | JC007, not JC004 |
| direct `perform` becomes unsupported keyword form | head worker contract unknown | JC007, not JC004 |
| new worker, no enqueue | class introduced only | no JC005 |
| new worker + head enqueue | base class proven absent; old process may consume queue | JC005 conditional-risk error |
| new head worker + enqueue, but base class remains unrecognized/outside scan | base absence not proven | JC007, not JC005 |
| new worker + splat enqueue | old fleet still lacks class | JC005 plus JC007 for head-to-head arity proof |
| head producer rejected by head, no qualifying base producer of same arity | current mismatch | JC003 error |
| head producer rejected by both base/head, no qualifying base producer of same arity | current mismatch | JC003 only |
| head producer accepted by base, rejected by head, no qualifying base producer of same arity | current mismatch | JC003 only |
| base producer rejected by both base/head | pre-existing mismatch | no JC001 |
| base producer accepted base, rejected head, and head emits same arity | shared head failure | one JC001 with `base_to_head` and `head_to_head`, no JC003 |
| no repository producer; head contract narrowed | queued history remains possible | JC006 warning, no queue-empty claim |
| worker contract unknown keywords | unproven | coalesced JC007 |
| base splat call | base-to-head unknown | JC007 warning |
| head splat call | head-to-base and head-to-head unknown | one JC007, two directions |
| dynamic call | worker null | JC007 warning |
| narrowing plus dynamic base call | distinct risks | JC006 + JC007 |
| parameter rename only | same interval | no finding |
| rest arg added | broadening | no finding |
| rest arg removed with witnessed large payload | regression | JC001 |

**De-duplication tests**

- multiple same-arity callsites aggregate into one JC001/JC002/JC003;
- different arities produce distinct findings when both incompatible;
- JC004 suppresses downstream missing-head errors only after completed absence proof;
- JC005 suppresses absent-base JC002 only after completed absence proof;
- JC001 owns the same worker/arity's head-to-head rejection and aggregates head producer locations; JC003 does not duplicate it;
- JC003 owns head-only mismatch and suppresses JC002 for that producer;
- JC001 prevents JC006 for the same proven narrowing;
- JC003 prevents JC006 when its current mismatch uses an arity accepted by base but removed by head;
- unchanged JC007 root in base/head yields one finding with `revisions: [base, head]`, unioned directions and both locations;
- different JC007 reasons, paths, scopes, expressions, or occurrence identities remain separate;
- an unchanged unsupported `perform` parameter list with an unrelated method-body edit retains one cross-revision JC007 root;
- two identical expressions in one scope produce two findings per revision and pair one-to-one only when group size and ordinals agree;
- changed duplicate multiplicity prevents ambiguous cross-revision pairing;
- one unknown AST node yields one JC007 even when two directions are affected;
- exact suppression removes all findings for that rule+worker but not another rule or namespace;
- warning-only and suppressed-error-only results exit 0;
- any remaining error exits 1.

**Completion criteria**

- all seven rule algorithms map line-by-line to `docs/spec-v0.1.md`;
- no rule relies on traversal or Hash insertion order;
- no JC004/JC005 is emitted from recognized-worker set difference alone.

### Phase 8 — text and JSON output

**Files**

```text
lib/jobcompat/formatter/text.rb
lib/jobcompat/formatter/json.rb
test/unit/text_formatter_test.rb
test/unit/json_formatter_test.rb
test/fixtures/output/*.txt
test/fixtures/output/*.json
```

**Implementation tasks**

- implement headers, comparison SHAs, deployment model, findings, risk, locations, remediation, and summary;
- implement `PASS` and `PASS WITH WARNINGS`;
- build JSON schema v1 completed and failed envelopes;
- include per-worker matrices;
- escape control characters and preserve UTF-8;
- enforce deterministic sorting before serialization;
- emit the fixed two-space pretty JSON shape plus exactly one terminal newline.

**Tests**

- exact golden text for each JC001–JC007;
- errors before warnings and stable rule/name/arity/location order;
- singular/plural summary grammar;
- no ANSI/control-sequence leakage;
- namespaced and Unicode paths display safely;
- completed JSON with error/warning/no finding/suppression;
- matched suppressions render deterministically in text and JSON without restoring suppressed findings;
- failed JSON for config, Git, and parse errors;
- every documented field present with null where unavailable;
- absent contracts serialize as null while unsupported contracts serialize as `status: unknown` objects;
- null contracts use `base_presence`/`head_presence` to distinguish class absence from unrecognized or out-of-scope declarations;
- `max_arity: null` for unbounded contracts;
- `revisions` and `directions` appear on every finding in canonical order; JC001 can carry both `base_to_head` and `head_to_head`;
- JC007 carries a fixed `unknown_reason`; an unchanged base/head root has one JSON finding with both revisions and all affected directions;
- JC004 and JC005 public text reflects static absence proof and JC005's conditional old-consumer risk;
- JC006 public text explicitly says missing repository producer evidence does not prove absence of queued, scheduled, retried, historical, or externally enqueued payloads;
- JSON parses and round-trips;
- exact bytes stable across repeated runs.

**Completion criteria**

- a reader can identify what changed, direction, risk, locations, and migration from the first finding without source lookup;
- formatters contain no interval membership or rule precedence logic.

### Phase 9 — end-to-end CLI orchestration

**Files**

```text
lib/jobcompat/cli.rb
test/integration/check_command_test.rb
test/integration/determinism_test.rb
```

**Implementation tasks**

- connect root/config/ref/snapshot/analyzer/engine/suppression/formatter;
- run the engine's pure presence-request preflight, resolve requested names through the lazy snapshot index, then call final pure rule evaluation;
- produce text and JSON failures according to stream policy;
- guarantee exit codes 0/1/2;
- avoid leaking backtraces for expected errors;
- permit running from nested directories;
- include requested refs and full resolved SHAs.

**Temporary-Git integration scenarios**

1. safe optional consumer expansion -> exit 0;
2. optional expansion plus head 2-arg producer -> JC002, exit 1;
3. required argument addition with base call -> JC001, exit 1;
4. head same-tree mismatch -> JC003, exit 1;
5. proven worker-class deletion from tracked `.rb` -> JC004, exit 1;
6. new worker and enqueue with proven base class absence -> conditional-risk JC005, exit 1;
7. narrowing without witness -> JC006, exit 0;
8. splat producer -> JC007, exit 0;
9. ignored JC005 -> exit 0 and suppressed count 1;
10. invalid base/head ref -> exit 2;
11. invalid config -> exit 2;
12. invalid Ruby in selected path -> exit 2;
13. invalid Ruby in excluded test path -> not parsed, normal result;
14. text and JSON outcomes contain the same finding counts/IDs;
15. invocation from a subdirectory finds root config;
16. explicit relative config resolves from invocation directory;
17. dirty working tree before/after bytes and status identical;
18. same base/head SHA still evaluates JC003 in that snapshot;
19. no network, Redis, Rails, or Sidekiq gem installed in the fixture.

**Required cross-revision integration matrix**

| Scenario | Expected result |
| --- | --- |
| same semantic `perform_async(*args)` JC007 root in base/head | one JC007, `revisions: [base, head]`, unioned directions, two revision-tagged locations |
| different JC007 roots by reason, source path, scope, expression, or occurrence | separate findings; no false merge |
| two identical unknown calls in one scope in both snapshots | two findings, paired by deterministic occurrence identity |
| base producer accepted by base and rejected by head, head producer same worker/arity also rejected by head | one JC001 with `base_to_head` and `head_to_head`, no JC003 |
| head producer mismatch without qualifying base evidence | standalone JC003 |
| actual deletion of base supported worker's class from head tracked `.rb` | JC004 error |
| direct include becomes indirect include, same class remains | JC007 warning, no JC004 |
| `perform` becomes unsupported keyword signature, same class remains | JC007 warning, no JC004 |
| file rename only, same canonical class and contract | no finding |
| class moved to another selected file | no finding |
| class moved to excluded or non-included tracked `.rb` | JC007 outside-analysis-scope warning, no JC004 |
| canonical class rename, old name proven absent | old name JC004 |
| canonical class rename plus new head enqueue and proven base absence of new name | old JC004 plus conditional-risk JC005 |
| include and `perform` in different selected files | one known merged worker contract |
| move only one reopened fragment or rename only one fragment file | same deterministic merged contract, no removal |
| move only the include fragment of a reopened class outside scan while `perform` remains selected | class still defined; JC007, no JC004 |
| move only the `perform` fragment outside scan while include remains selected | unknown contract JC007, no JC004 |
| excluded candidate-bearing blob cannot parse or presence scan hits 64 MiB budget | JC007 presence-unverified, no JC004/JC005 |
| new head worker enqueued but base class remains unrecognized or out of scan | JC007, no JC005 |
| new head worker with no head enqueue | no JC005, base presence `not_checked` in JSON |
| no repository producer and known worker contract narrows | JC006 warning; output does not infer queue emptiness |

**Determinism tests**

- create identical logical repositories with different file creation order and compare output;
- repeat command multiple times and compare bytes;
- callsites inserted in reverse lexical/tree order still sort identically;
- JSON object keys and arrays match golden files;
- summary counts remain consistent with findings/suppression.
- JC007 fingerprint and occurrence pairing are byte-stable across file creation/traversal order;
- one cross-revision JC007 warning counts once in text, JSON, and summary.

**Completion criteria**

- the executable passes a true subprocess test for each exit code and format;
- manual invocation on a fixture visibly matches the documented example.

### Phase 10 — README, CI, packaging, and release-readiness (no publish)

**Files**

```text
README.md
.github/workflows/ci.yml
jobcompat.gemspec
LICENSE
CHANGELOG.md          # optional but recommended for public OSS
```

**Implementation tasks**

- write README in the exact outline from the spec;
- put the diff/error five-second example in the first screen;
- document native Sidekiq only and positional-arity-only limits;
- add the standard MIT license text for `2026 jobcompat contributors`;
- include installation, quick start, rules, config, CI, safety, and staged migration;
- add CI for supported Ruby 3.3, 3.4, and 4.0 using available current patch releases;
- run unit/integration suite and gem build in CI;
- verify gem contents include executable, lib, README, license, and docs but not temp files;
- add no release automation in v0.1 implementation unless separately requested.

**Tests/checks**

- all code blocks are syntactically coherent with the actual CLI;
- README command output matches formatter fixtures;
- `gem build` succeeds;
- install built gem into a temporary gem home and run help/version/check fixture;
- CI workflow does not require Redis or network beyond dependency installation;
- dependency/license metadata is correct;
- gem metadata omits repository/homepage URLs until a real public URL exists;
- `rg` confirms no README claim of ActiveJob/BullMQ/Celery support;
- link check where practical, with network failures reported rather than guessed.

**Completion criteria**

- a new user can understand value, install, run, interpret failure, and suppress a gated false positive from README alone;
- no commit, push, tag, release, or RubyGems publish occurs without a separate user request.

## 4. Concrete test inventory

The phase tests above are normative. The following file-level inventory prevents coverage gaps.

### `worker_discovery_visitor_test.rb`

- modern/legacy includes;
- top-level, nested modules, explicit class paths, root paths;
- multiple includes and parentheses;
- non-worker exclusions;
- inherited/concern/dynamic limitations;
- reopened classes;
- same leaf name under separate namespaces;
- nested context restoration;
- zero/multiple perform definitions.
- presence index exact/ambiguous class names, static named bindings, and selected/out-of-scope locations;
- deterministic fragment merge when include/perform files move independently.

### `defined_constant_index_test.rb`

- normal selected AST reuse and lazy excluded-blob presence-only parsing;
- leaf-token prefilter does not treat a reference as a definition;
- exact present, unrecognized, outside-scope, absent, and unverified outcomes;
- ambiguous paths, excluded parse/encoding failure, and 64 MiB budget block absence ERROR;
- presence-only source does not add producer facts or normal scan counts.

### `worker_contract_test.rb`

- min/max for every positional signature form;
- unbounded `nil` representation;
- accepts below/min/inside/max/above;
- interval superset finite/finite, finite/unbounded, unbounded/finite, unbounded/unbounded;
- parameter-name independence;
- unsupported keywords are not fake ranges.

### `producer_discovery_visitor_test.rb`

- async/in/at/set syntax;
- zero/hash/array/keyword-hash payload slots;
- nested namespaces and root qualification;
- splat/forwarding/malformed schedule;
- dynamic/safe-navigation receivers;
- ignored low-level/bulk/metaprogrammed APIs;
- source locations at the outer enqueue call.
- semantic fingerprint retains kind, reason, worker, path, lexical scope, normalized expression/statement, group size, and ordinal while excluding revision and line/column.

### `compatibility_engine_test.rb`

- all four matrix cells and status precedence;
- all A/B/C directions;
- optional-argument safe/unsafe rollout split;
- pre-existing mismatch exclusion;
- missing/new consumer states;
- known and unknown calls in combination.

### `rules_test.rb`

- one focused test per precondition branch for JC001–JC007;
- examples from the formal spec;
- false-positive-oriented cases such as feature-flag suppression;
- aggregation and precedence;
- exact suppression behavior;
- title/severity/directions/remediation public values.
- JC004/JC005 each require opposite-snapshot `absent`, not merely a missing recognized worker;
- JC001 absorbs same worker/arity JC003 and carries both directions;
- JC007 pairs exact roots across revisions without merging distinct occurrences.

### `git_repository_test.rb`

- real object reads from base/head commits;
- path framing and mode filtering;
- ref safety and moving refs;
- missing objects/errors;
- non-mutation proof.

### `check_command_test.rb`

- exit 0/1/2;
- text/JSON;
- invalid ref/config/source;
- default and explicit config;
- warnings-only behavior;
- stdout/stderr contract;
- help/version.

### `determinism_test.rb`

- finding order;
- location order;
- worker matrix order;
- unique numeric arity order;
- JSON key/array order and newline;
- repeated byte equality;
- summary reconciliation.

## 5. Manual QA gate

After automated tests pass, perform this exact user flow in a temporary Git repository:

1. commit base with `ExportJob#perform(user_id)` and a one-argument producer;
2. commit head with `perform(user_id, format = nil)` and a two-argument producer;
3. make an unrelated dirty working-tree edit;
4. run `jobcompat check --base <base-sha>`;
5. observe JC002, `HEAD producer -> base consumer`, remediation, base/head consumer plus head producer locations, and exit 1;
6. run JSON format and inspect parsed `schema_version`, matrix, finding, summary, and exit 1;
7. add a temporary `.jobcompat.yml` suppression with reason and observe exit 0, suppressed count, and the matched suppression audit record;
8. run `git status --porcelain` and byte-compare the dirty file before/after;
9. replace explicit head call with splat and observe JC007 warning plus exit 0;
10. corrupt one selected Ruby file in a commit and observe parse diagnostic plus exit 2.

This flow is required because unit tests alone do not prove the installed CLI, Git protocol, streams, or visible UX.

## 6. Documentation consistency review

Before declaring v0.1 complete, compare implementation and README against all four planning documents. Resolve these checks explicitly:

1. ERROR conditions use supported, deterministic set/range evidence.
2. Base-to-head and head-to-base are both exercised by integration tests.
3. Optional argument addition alone passes; starting to produce it triggers JC002.
4. Proven class absence triggers JC004 only; a defined, excluded, or unverified class yields JC007 instead.
5. New worker plus enqueue triggers JC005 only with proven base absence; class addition alone does not, and its risk text is conditional on old queue consumption.
6. Splat/dynamic/keyword cases are unknown, never pass.
7. No ActiveJob or other framework code entered v0.1.
8. The codebase still reflects one parser and one framework, without an adapter platform.
9. AST extraction has no rule decisions; engine has no Prism nodes.
10. Tests specify all public behavior without relying on network or Redis.
11. README's first screen contains the five-second value example.
12. Competitive claims use “none found in bounded research,” not absolute absence.
13. An unchanged JC007 root reports once across base/head, while distinct roots remain distinct.
14. A shared old/current mismatch is one multi-direction JC001; head-only mismatch is JC003.
15. File rename and selected reopened-fragment movement do not imply class removal.
16. No producer callsite is treated as proof that queues, retries, scheduled, or historical payloads are empty.
17. JC004/JC005 absence proofs use the bounded tracked-`.rb` presence pass; unverified results never become ERROR.

## 7. Recommended first implementation action

Start by selecting/installing a supported Ruby 3.3+ toolchain and implementing **Phase 0** only. Verify the gem builds and `jobcompat --help/--version/check --help` work before adding Git or AST behavior. The next increment should be strict config, then the immutable Git loader; this order gives every later parser/rule test a trustworthy input boundary.
