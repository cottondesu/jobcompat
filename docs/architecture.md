# jobcompat v0.1 architecture

Status: implementation design for `0.1.0`
Date: 2026-09-23

## 1. Architecture principles

1. **Immutable inputs:** analyze Git commits without changing the checkout.
2. **No application execution:** parse source; never require, boot, or evaluate it.
3. **Extraction before semantics:** AST visitors produce facts; a pure engine compares facts.
4. **Conservative unknowns:** unsupported evidence is explicit and cannot become a pass.
5. **Small v0.1 surface:** one framework adapter, one parser, one command, two formatters.
6. **Determinism:** stable sorting and fully resolved commit SHAs are part of correctness.
7. **No speculative framework abstraction:** namespaces organize current responsibilities; no generic plugin API ships in v0.1.

## 2. Data flow

```text
 Git base ref                         Git head ref
      |                                    |
      v                                    v
 resolve SHA + ls-tree metadata      resolve SHA + ls-tree metadata
      |                                    |
      v                                    v
 selected blobs -> Prism AST         selected blobs -> Prism AST
      |                                    |
      v                                    v
 worker fragments + producer facts + selected DefinedConstantIndex facts
                       |
                       v
          pure engine presence-request preflight
                       |
                       v
      lazy presence-only pass on requested snapshot/name pairs
                       |
                       v
      pure Compatibility::Engine (contracts, matrices, rules,
          JC007 semantic pairing and finding aggregation)
                       |
                       v
             suppression -> text / JSON
```

The same selected source blob is parsed once per distinct blob OID. When base and head contain the same OID, the parse/extraction result MAY be memoized and rebound to the appropriate revision label. The presence-only pass is lazy for potential JC004/JC005 names and checks tracked `.rb` blobs outside normal scan scope without using their producer facts. Caching is in-process only.

## 3. Proposed project layout

```text
jobcompat.gemspec
Gemfile
Rakefile
LICENSE
README.md

exe/
  jobcompat

lib/
  jobcompat.rb
  jobcompat/
    version.rb
    cli.rb
    config.rb
    errors.rb

    git_repository.rb
    revision_snapshot.rb

    analysis/
      sidekiq_analyzer.rb
      worker_discovery_visitor.rb
      producer_discovery_visitor.rb
      defined_constant_index.rb
      semantic_evidence.rb
      constant_name.rb

    model/
      source_location.rb
      worker_contract.rb
      enqueue_call.rb
      compatibility_result.rb
      finding.rb

    compatibility/
      engine.rb
      rules.rb

    formatter/
      text.rb
      json.rb

test/
  test_helper.rb
  support/
    temporary_repository.rb
  unit/
    config_test.rb
    constant_name_test.rb
    worker_contract_test.rb
    compatibility_engine_test.rb
    rules_test.rb
    text_formatter_test.rb
    json_formatter_test.rb
  analysis/
    worker_discovery_visitor_test.rb
    producer_discovery_visitor_test.rb
    sidekiq_analyzer_test.rb
  integration/
    git_repository_test.rb
    check_command_test.rb
    determinism_test.rb

docs/
  competitive-analysis.md
  spec-v0.1.md
  architecture.md
  implementation-plan.md
```

This structure is intentionally shallower than a multi-framework architecture. If a second framework is implemented later, extraction can then gain an adapter interface based on observed commonality.

## 4. Component responsibilities

### 4.1 `Jobcompat::CLI`

- parse `ARGV` using `OptionParser`;
- implement `check`, top-level help, command help, and version;
- locate the Git root;
- load configuration;
- orchestrate snapshots, analysis, engine, suppression, formatting, and exit status;
- translate expected exceptions into user-facing tool errors;
- never contain rule logic or AST branching.

The executable calls one public entry point and exits with its integer result. It MUST NOT rescue `SystemExit` broadly or hide programming failures as compatibility findings.

### 4.2 `Jobcompat::Config`

- supply defaults;
- load YAML with `Psych.safe_load` and aliases disabled;
- reject unknown keys/types/duplicates;
- compile scan glob lists without reading source files;
- expose `scan?(path)` and `suppresses?(finding)`;
- retain display path for JSON output.

No rule severity customization or plugin configuration belongs here in v0.1.

### 4.3 `Jobcompat::GitRepository`

- find repository root;
- resolve a ref to a full commit SHA;
- enumerate regular blobs in a tree with NUL-delimited output;
- stream selected blob contents using one `git cat-file --batch` process per snapshot or per complete comparison;
- retain path/mode/OID metadata for every tracked `.rb` blob so a later bounded presence-only pass can examine excluded paths without rescanning the Git tree;
- build `RevisionSnapshot` metadata;
- raise typed Git errors with sanitized messages.

It MUST NOT expose a general shell runner.

### 4.4 `Jobcompat::RevisionSnapshot`

Immutable metadata and extracted analysis for one revision:

```text
label          : base | head
requested_ref  : String
sha            : 40/64-character object ID as emitted by Git
workers        : Hash<String, WorkerContract or UnknownContract>
enqueue_calls  : Array<EnqueueCall or UnknownEnqueueCall>
constant_index : DefinedConstantIndex
tracked_ruby   : lazy path/OID metadata for regular .rb blobs
files_scanned  : Integer
```

The snapshot does not retain every source file after analysis. Selected ASTs contribute declaration facts to `DefinedConstantIndex`; unselected blobs are opened only if a potential JC004/JC005 needs a presence proof. `files_scanned` counts only normal selected files, not presence-only blobs.

### 4.5 `Jobcompat::Analysis::SidekiqAnalyzer`

- call `Prism.parse(source, filepath: path)`;
- turn any Prism error diagnostic into a typed parse failure;
- run worker and producer visitors over the same AST;
- return syntax facts without compatibility conclusions;
- preserve source locations and concise signature/call excerpts.

It receives source bytes and a revision/path context. It does not open files, invoke Git, or know base/head rule semantics.

### 4.6 AST visitors

`WorkerDiscoveryVisitor` owns class/module namespace tracking, direct Sidekiq includes, and direct `perform` definitions.

`ProducerDiscoveryVisitor` owns calls named `perform_async`, `perform_in`, and `perform_at`, supported `.set` chains, syntactic payload counts, lexical namespace capture, and unknown call facts.

`ConstantName` is a small utility that flattens only `ConstantReadNode` and `ConstantPathNode`. It returns a value object with `segments`, `root_qualified`, and `static`; it does not resolve Ruby constants.

`DefinedConstantIndex` records exact or plausible canonical class/module declarations and statically named constant bindings, source locations, and normal-scan membership. It is distinct from supported Sidekiq worker recognition. For a name missing from one revision's recognized workers, it returns `recognized_worker`, `defined_unrecognized`, `outside_scan_scope`, `absent`, or `unverified` using the formal proof in the spec. A present-but-unrecognized class or incomplete presence pass blocks JC004/JC005 ERROR.

`SemanticEvidence` builds the revision-free JC007 fingerprint from uncertainty kind/reason, canonical worker when known, sorted relative paths, syntactic enclosing scope, trivia-free relevant token stream and enclosing statement, plus deterministic group size and occurrence ordinal. It retains every revision-tagged root location. Same-fingerprint roots pair one-to-one across snapshots; distinct roots remain separate.

### 4.7 `Compatibility::Engine`

- accept fully extracted base/head snapshots and configuration-independent facts;
- resolve producer names against the combined worker-name index;
- expose a pure preflight that identifies the canonical names needing opposite-snapshot presence checks after producer resolution; consume the resulting immutable presence statuses during rule evaluation;
- calculate matrices;
- evaluate rule algorithms and precedence;
- aggregate/de-duplicate findings;
- return a `CompatibilityResult` without printing or exiting.

The engine MUST be pure with respect to filesystem, Git, environment, clock, and output streams. This is the main unit-test seam.

### 4.8 Formatters

Formatters receive a completed or failed result envelope. They MUST NOT recalculate compatibility or suppression. They render already matched suppression audit records without reconstructing omitted findings.

- `Formatter::Text` renders concise human remediation.
- `Formatter::Json` constructs schema-version-1 primitive Hash/Array data, including each finding's `revisions`, `directions`, and `unknown_reason` and each worker's base/head presence status, calls `JSON.pretty_generate`, and appends exactly one newline. The formal specification fixes two-space pretty JSON; exact-output tests lock it.

Both consume already sorted results.

## 5. Git revision loading

### 5.1 Why not checkout/worktree copies

| Approach | Advantages | Problems | Decision |
| --- | --- | --- | --- |
| `git checkout` base/head | simple filesystem reads | mutates user state, conflicts with uncommitted changes, slow | reject |
| temporary `git worktree` | isolates checkout | creates/deletes directories and Git metadata; checkout filters may run | reject for v0.1 |
| one `git show <sha>:<path>` per file | immutable and simple | one subprocess per file; poor large-repo performance | reject |
| `git archive` | one stream | honors archive behavior such as `export-ignore`; tar layer; less direct object control | reject |
| `ls-tree` + `cat-file --batch` | immutable, raw blobs, few processes, path-safe enumeration | framed-stream parser required | adopt |

### 5.2 Command protocol

All commands are invoked as argv arrays with `Open3`, never through a shell.

1. Locate root:

   ```text
   git rev-parse --show-toplevel
   ```

2. Resolve ref:

   ```text
   git rev-parse --verify --end-of-options <ref>^{commit}
   ```

   Every command after root discovery runs with `chdir` set to that exact Git root.

3. Enumerate tree using the resolved SHA:

   ```text
   git ls-tree -r -z --full-tree <sha>
   ```

4. Split each NUL-terminated default-format record at its first tab into `<mode> <type> <oid>` and the path; then filter mode/type/path in Ruby. Keep metadata for all regular tracked `.rb` blobs, but parse only normal-scan paths initially.
5. Feed only hexadecimal object IDs to:

   ```text
   git cat-file --batch
   ```

6. Parse each response as `<oid> <type> <size>\n`, exactly `size` bytes, then one delimiter newline.

Only OIDs, not user paths or refs, enter the batch input. NUL-delimited tree enumeration preserves unusual Git pathnames. v0.1 rejects paths containing NUL by construction (Git paths cannot contain NUL) and can preserve newlines because the path is never sent through line-based batch input.

Set `GIT_OPTIONAL_LOCKS=0` for read-only intent. Do not request textconv, filters, or symlink following. Capture stderr and convert non-zero status into `GitError` without leaking irrelevant environment data.

### 5.3 Missing or moving refs

The ref may move after resolution without affecting analysis because every later command uses its SHA. Missing refs, non-commit objects that cannot peel to commits, missing objects in a partial clone, corrupt batch framing, or Git command failure make the analysis incomplete and exit 2.

No implicit `git fetch` occurs. Network access is never required by jobcompat.

### 5.4 Lazy presence-only pass

The pure engine preflight returns HEAD names for all base-only workers and base names for head-only workers with an attributable head enqueue. The CLI then resolves those requests through each snapshot's index before final engine evaluation; the engine never performs I/O. A head-only worker with no head enqueue needs no base query and has `not_checked` base presence in JSON. Selected ASTs already supply declarations. For unselected regular tracked `.rb` blobs, stream bytes and prefilter on the candidate leaf constant token; only candidate-bearing blobs need Prism. Non-ASCII candidate leaves require parsing all unselected blobs within the same budget. This pass never extracts producers or worker contracts, and excluded-file syntax errors do not become global parse errors. An exact declaration/binding gives `outside_scan_scope`; an ambiguous declaration, candidate-bearing parse failure, or exhausted budget gives `unverified`. `absent` is returned only after every relevant blob is checked within the 64 MiB (67,108,864 byte) unselected-byte budget. The prefilter and budget bound expensive vendor trees; a budget hit sacrifices an ERROR proof and produces JC007. No checkout, application execution, or source retention is required.

## 6. Prism strategy

### 6.1 Parser decision

Prism is selected over `parser` because:

- Prism is official, production-ready, error-tolerant, and bundled from Ruby 3.3;
- the target runtime is Ruby 3.3+;
- native Prism AST exposes source locations and named node fields directly;
- the `parser` project itself recommends native Prism for Ruby 3.3+ when its legacy AST compatibility is not required;
- jobcompat is new code and has no existing `parser` AST investment.

The `parser` gem remains stronger when one tool must parse historical Ruby grammars with its long-stable AST. That is not a v0.1 goal. No parser abstraction is added.

### 6.2 Parse result handling

For every selected blob:

1. `result = Prism.parse(source, filepath: path)`;
2. if `result.errors.any?`, record every located error; continue over sorted selected files only to aggregate parse errors, then abort compatibility analysis with exit 2;
3. parse warnings MAY be logged or asserted during development but do not appear in v0.1 public findings or completed diagnostics;
4. visit `result.value` once, dispatching both fact collectors or one combined traversal;
5. use node `location.start_line` and `start_column` and convert columns to documented 1-based values.

Prism columns are byte-based in source encoding; JSON/text reports 1-based byte columns in v0.1. This MUST be stated in developer documentation to avoid Unicode ambiguity.

Presence-only blobs reuse this parser with a narrower visitor. A candidate-bearing parse/encoding error makes the candidate's presence `unverified`; it does not fail the entire analysis because the file was excluded from the normal scan. Selected-file errors retain exit 2.

### 6.3 Node mapping

| Concern | Prism nodes/fields | Extracted information |
| --- | --- | --- |
| class | `ClassNode#constant_path`, `#body` | declared static name, body namespace |
| module | `ModuleNode#constant_path`, `#body` | lexical namespace |
| constant path | `ConstantReadNode#name`, `ConstantPathNode#parent/#name` | static segments and root qualification |
| class/module presence | `ClassNode`/`ModuleNode` and statically named constant writes | exact or plausible canonical name, normal-scan status, source location |
| include | `CallNode#name == :include`, `#receiver == nil`, `ArgumentsNode#arguments` | exact Sidekiq module argument and location |
| perform | `DefNode#name == :perform`, `#receiver == nil`, `#parameters` | direct instance signature only |
| positional parameters | `ParametersNode#requireds/#optionals/#rest/#posts` | min/max arity |
| keywords | `ParametersNode#keywords/#keyword_rest` | unsupported status, except forwarding node |
| forwarding | `ForwardingParameterNode` | unbounded positional acceptance |
| enqueue call | `CallNode#name/#receiver/#arguments/#block` | method, receiver fact, argument nodes, location |
| safe navigation | `CallNode#call_operator_loc` whose source slice is `&.` | unknown receiver evidence |
| call arguments | `ArgumentsNode#arguments` | syntactic count |
| splat | `SplatNode` | unknown producer arity |
| forwarded call args | `ForwardingArgumentsNode` | unknown producer arity |
| `.set` chain | outer `CallNode(:perform_async)` receiver inner `CallNode(:set)` | underlying worker receiver; outer payload args |
| source location | every node's `#location` | revision, path, line, column, concise source excerpt |
| unknown evidence | relevant node source tokens and enclosing statement | revision-free semantic fingerprint parts and occurrence ordering |

### 6.4 Visitor state

Namespace tracking uses a stack of static segment arrays. Entering `module Admin; class ExportJob` pushes `Admin`, then `ExportJob`. At top level, entering `class Admin::ExportJob` pushes the full declared path as one lexical scope value. A root-qualified path is exact. An unrooted multi-segment class/module path inside a non-empty lexical namespace is unsupported rather than guessed. The visitor MUST restore state with `ensure` so exceptions do not corrupt sibling traversal.

Each class fragment has its own context:

```text
canonical_name
declaration_location
recognized_include_locations[]
perform_nodes[]
```

The discovery visitor must avoid treating `include` inside a nested class as belonging to its parent.

Group all selected class fragments by canonical name within one revision before deciding whether the worker has one direct `perform`. An include fragment and a `perform` fragment can be in different files; a file move alone cannot delete the canonical worker. The merge derives only the supported Sidekiq positional contract: zero or multiple direct `perform` definitions use the existing `missing_perform` or `multiple_perform_definitions` unknown reasons. Unsupported canonical paths remain unknown, and the separate presence index blocks a false JC004. This aggregation does not reconcile general Ruby class/module kind, superclass, constant, autoload, or runtime load-order conflicts.

### 6.5 Producer facts before name resolution

The producer visitor emits an unresolved fact:

```text
UnresolvedEnqueueCall
  receiver_kind       static_constant | dynamic | unsupported
  receiver_segments   Array<String> | nil
  root_qualified      true | false
  lexical_namespace   Array<String>
  payload_arity       Integer | nil
  arity_known         true | false
  method              perform_async | perform_in | perform_at
  location
unknown_reason      Symbol | nil
```

The symbol values map one-to-one to the schema-v1 strings enumerated in `docs/spec-v0.1.md`; visitors do not invent free-form reason text.

Only after both revisions' worker names are known does the engine resolve these facts. This avoids ordering dependence between files and enables head calls to removed base workers.

## 7. Internal models

Models SHOULD be immutable `Data.define` values on Ruby 3.3. Constructors validate invariants at the boundary; rule methods do not repeatedly revalidate them.

### 7.1 `SourceLocation`

```text
revision : :base | :head
path     : String
line     : Integer >= 1
column   : Integer >= 1
role     : :consumer | :producer | :worker_declaration | :unknown_call
excerpt  : String | nil
```

### 7.2 `WorkerContract`

```text
name            : String
min_arity       : Integer >= 0
max_arity       : Integer >= min_arity | nil
variadic        : Boolean derived from max_arity.nil?
signature_kind  : :positional | :forwarding
declaration_locations : Array<SourceLocation>
include_locations     : Array<SourceLocation>
perform_location      : SourceLocation
signature       : String
```

Methods:

```text
accepts?(arity) -> Boolean
superset_of?(other_contract) -> Boolean
display_range -> String
```

All location arrays are sorted and deduplicated after canonical fragment merge. Unknown contracts are a separate `UnknownWorkerContract` carrying name, all relevant fragment locations, and a reason enum. Do not encode unknown as fake `0..∞`.

The JSON formatter serializes both classes as a contract object with `status: known|unknown`. A null contract means no recognized worker contract in that revision; the separate `base_presence`/`head_presence` enum distinguishes proven class absence from an unrecognized, out-of-scope, or unverified class. Null alone MUST NOT drive JC004 or JC005.

### 7.3 `EnqueueCall`

```text
worker_name    : String | nil
payload_arity  : Integer | nil
arity_known    : Boolean
method         : :perform_async | :perform_in | :perform_at
location       : SourceLocation
unknown_reason : Symbol | nil
```

Invariant: known arity implies non-null worker and payload arity. A known worker with unknown arity is valid. A null worker is always unknown evidence.

### 7.4 `CompatibilityResult`

```text
base_snapshot
head_snapshot
workers[]
findings[]
matched_suppressions[]
diagnostics[]
summary
status
```

Per-worker results contain base/head contracts, unique producer arity lists, unknown call counts, and four matrix cell statuses.

### 7.5 `Finding`

```text
rule_id         : JC001..JC007
title           : String
severity        : :error | :warning
worker          : String | nil
revisions       : non-empty Array<Symbol> in base/head order
directions      : non-empty Array<Symbol>
unknown_reason  : Symbol | nil, set for JC007 only
message         : String
risk            : String
remediation     : Array<String>
payload_arity   : Integer | nil
locations       : Array<SourceLocation>
```

Rule titles and default remediation text live in `compatibility/rules.rb`, not formatters.

## 8. Compatibility engine

### 8.1 Pure calculation order

1. index known and unknown workers by canonical name;
2. build union name index;
3. resolve producer facts for each revision;
4. group known calls by worker and arity;
5. build base/base, base/head, head/base, head/head cells;
6. produce pure presence requests for potential JC004/JC005; after the CLI supplies immutable statuses, emit ERROR only on `absent`, otherwise queue a presence JC007;
7. evaluate JC001, then JC003 and JC002 membership relations; merge the same worker/arity's head-to-head failure into JC001;
8. evaluate JC006 interval inclusion;
9. translate unknown facts/contracts/presence transitions to JC007;
10. pair exact semantic fingerprints across base/head, union revisions/directions/locations, then aggregate and sort;
11. apply config suppressions outside the engine or in a dedicated result filter, retaining matched rule/worker/reason/count audit records;
12. compute summary and exit policy.

### 8.2 Rule isolation

Rule implementation SHOULD use small functions returning zero or more findings:

```text
Rules.worker_removed(context)
Rules.new_worker_activated(context)
Rules.current_mismatch(context)
Rules.old_payload_rejected(context)
Rules.new_payload_rejected_by_old(context)
Rules.contract_narrowed(context)
Rules.unproven(context)
```

The engine owns precedence by passing an evidence-ownership set keyed by worker and payload arity. JC001 claims any matching head-to-head failure before JC003; JC003 claims remaining head failures before JC002. Individual rules do not inspect already formatted findings.

### 8.3 Aggregation key

Default key:

```text
[rule_id, worker, payload_arity]
```

JC004, JC005, and JC006 use a worker-level key with null payload arity. `directions` and `revisions` are unioned values, never key components. JC007 uses the full semantic evidence fingerprint from the spec, excluding revision and line/column, rather than primary location. Multiple identical roots within one revision remain separate by occurrence identity. A changed count or ambiguous pairing does not merge across revisions.

Before returning a finding, the engine attaches the complete proof locations defined in the rule catalog: relevant producer callsites and every base/head consumer contract used by the membership decision. Formatters never infer or add evidence.

## 9. Error architecture

Expected failures use typed exceptions under `Jobcompat::Error`:

```text
UsageError
ConfigError
GitError
ParseError
InternalError (conversion boundary only)
```

`CLI` converts these to exit 2 and a text or JSON diagnostic. The original Git/Prism message can be included after path/ref sanitization. No application source body beyond a single relevant line should be echoed in errors.

Unexpected exceptions are caught only at the executable boundary to preserve CLI exit 2. During tests, a configurable runner MAY re-raise so failures retain backtraces. v0.1 has no public debug flag.

## 10. Output architecture

The engine/result layer supplies all semantic strings or structured data needed by both formats. Text-specific wrapping and labels stay in Text; JSON field construction stays in JSON.

Do not derive the JSON document by parsing text output. Do not embed ANSI codes. Use explicit singular/plural helpers only in Text.

JSON output is treated as a public API. A fixture/golden test locks a representative success, warning, error, suppression, and tool-failure document.

## 11. Dependency decisions

### Runtime

| Dependency | Decision | Reason |
| --- | --- | --- |
| `prism >= 1.9, < 2` | include | official native AST and diagnostics; only non-stdlib runtime dependency |
| `sidekiq` | exclude | analysis must not boot or load target framework |
| Thor | exclude | one subcommand; `OptionParser` is sufficient |
| `parser`/`ast` | exclude | Prism native AST selected; extra abstraction/dependencies add no v0.1 value |
| JSON/YAML/Open3/OptionParser | standard library/default gems | sufficient for serialization, safe config, subprocess, CLI |

### Development/test

Choose Minitest over RSpec. Minitest provides assertions, spec-style syntax if desired, low boot overhead, and fewer dependencies. The project needs data-driven tables and integration helpers more than an extensive DSL. Use `minitest`, `rake`, and optionally `simplecov` only if coverage enforcement is explicitly adopted during implementation; do not add SimpleCov by default merely for a number.

## 12. Performance and resource behavior

- enumerate each commit once;
- parse selected `.rb` blobs for full analysis; for only potential JC004/JC005 names, stream excluded tracked `.rb` blobs through a literal leaf-token prefilter and parse candidate-bearing blobs for presence only;
- cap the unselected presence pass at 64 MiB per snapshot; if exceeded, mark unresolved candidates `unverified` and emit JC007 rather than an ERROR;
- parse each unique blob OID once per process;
- stream blobs and release source/AST references after extracting facts;
- avoid worker threads in v0.1 until profiling proves parsing is a bottleneck;
- do not use `git diff` to scan only changed files because unchanged producers/consumers are required for cross-revision semantics;
- avoid repository-wide source snippets in results.

No hard source-file-size limit is configured in v0.1. The implementation SHOULD handle I/O incrementally and MAY add a documented safety limit only with a clear diagnostic, not silent skipping.

## 13. Security and privacy

The v0.1 security posture is a product characteristic:

- local source remains local;
- no source upload or telemetry;
- no external APIs;
- no Redis credentials;
- no application execution;
- no YAML object construction;
- no shell interpolation;
- no Git checkout filters or hooks;
- findings contain only necessary source lines/locations.

Threat boundary: the repository and config may be untrusted input. Prism and Git process those bytes, but jobcompat never evaluates Ruby. JSON/text escaping MUST prevent control characters in paths/excerpts from corrupting output framing. Text formatter should escape non-printable path characters; JSON handles them through the JSON encoder.

## 14. Future extension points without v0.1 over-engineering

The following seams are sufficient:

- `SidekiqAnalyzer` can later be joined by another analyzer behind a newly designed interface;
- `EnqueueCall` and `WorkerContract` represent framework-neutral concepts at the arity level, but fields should not be generalized prematurely;
- rule IDs remain product-level even if future adapters add their own namespaces;
- JSON `schema_version` and additive fields support integrations;
- a later SARIF formatter can consume `Finding` without changing the engine;
- a later live-queue mode must be a separate explicit command/input source, not silently mixed into static `check`.

Potential roadmap order:

1. more native Sidekiq producer forms (`Client.push`, bulk) after precision research;
2. SARIF/GitHub integration;
3. optional changed-path performance hints without weakening whole-snapshot facts;
4. ActiveJob as a separately specified adapter;
5. other ecosystems only after defining their serialization/deployment contracts.

Do not add an adapter registry, dependency injection container, generic AST facade, or rule plugin system in v0.1.
