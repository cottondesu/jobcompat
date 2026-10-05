# jobcompat v0.3.0 delta specification

Status: normative for 0.3.0. This document extends `spec-v0.2.1.md`,
which retains the v0.2 and v0.1 contracts except where overridden here.
MUST and MUST NOT state requirements. No application Ruby is executed.

## Versioned and frozen contracts

Gem and CLI version: 0.3.0. Completed and failed JSON envelopes MUST use
`schema_version: 3`. Configuration version remains exactly 1; version 2 is
invalid. Ruby >= 3.3 and Prism >= 1.9, < 2 remain unchanged. No dependency
on Sidekiq is introduced. JC001-JC007 IDs, severities (JC001-JC005 ERROR,
JC006-JC007 WARNING), exit policy, suppression identity, and deployment
directions remain unchanged. ERROR requires provable structural
incompatibility. Unknown and unsupported evidence never establishes
compatibility; missing producers never establishes an empty queue.
Analysis reads committed Git objects and ignores working-tree edits.

## Terminology and serialization

**Serialized worker identity** is the exact String in a Sidekiq payload's
`"class"` field. All compatibility comparisons use that identity.
**Direct worker** is a canonical class recognized through the existing
direct `Sidekiq::Job` or legacy `Sidekiq::Worker` include and reopened-class
discovery. **Compatibility alias** is a statically provable constant
binding to another constant whose graph terminates in one recognized
direct worker in the same revision. **Alias terminal** is that final
direct worker after zero or more supported edges.
**Class-object producer** passes a Ruby Class object (worker APIs,
Setter APIs, or Client constant payloads). **Exact-string producer** passes
an already serialized identity through Client push or push_bulk.

For `OldJob = NewJob`, Ruby retains the Class object's canonical name
`NewJob`. Class-object producers through OldJob MUST therefore normalize
to NewJob. This applies to perform_async, perform_in, perform_at,
perform_bulk, all four `.set(...)` forms, and Client push/push_bulk with a
constant. A Client `"class" => "OldJob"` MUST retain exactly OldJob on the
producer side; consumer lookup MAY resolve OldJob through its alias.
There is no namespace prefixing or Unicode normalization of exact Strings.

The model freezes Sidekiq's Class-to-String normalization as observed in
[Sidekiq 8.1.6 JobUtil](https://github.com/sidekiq/sidekiq/blob/v8.1.6/lib/sidekiq/job_util.rb#L38-L55)
and its [Class-object producer path](https://github.com/sidekiq/sidekiq/blob/v8.1.6/lib/sidekiq/job.rb#L191-L196).
The [official rename FAQ](https://github.com/sidekiq/sidekiq/wiki/FAQ#how-do-i-safely-rename-a-worker)
describes a compatibility alias for retained old payloads. Client Strings
have different job-option/default semantics; their identity behavior is
documented here without recommending them as a migration strategy.

## Supported syntax and namespace semantics

Only Prism ConstantWriteNode and ConstantPathWriteNode with plain `=`
and a ConstantReadNode or static ConstantPathNode RHS after safe
single-expression parentheses unwrapping prove an alias. The assignment
MUST be a direct unconditional statement in the Program body or a valid
Class/Module body, with all enclosing contexts supported.

Supported examples are `OldJob = NewJob`, `OldJob = (NewJob)`,
`::OldJob = ::NewJob`, top-level `Admin::OldJob = Admin::NewJob`, and
`module Admin; OldJob = NewJob; end`. Existing declaration rules determine
the LHS canonical name. An unrooted qualified LHS in lexical nesting or
an unsupported namespace MUST NOT prove an alias. An unrooted qualified
RHS inside lexical nesting is unsupported_alias_assignment. Rooted RHS
references and qualified top-level RHS references are exact.

Unqualified RHS lookup uses the existing lexical namespace stack in
reverse order, then the root name. For nested Admin/Jobs, NewJob candidates
are Admin::Jobs::NewJob, Admin::NewJob, NewJob. The first selected-source
binding wins lookup; a binding with an unknown value MUST block fallback
to a farther known worker. No inherited-constant lookup is added.

Assignments below if/unless/case/loops/blocks/lambdas/begin/rescue/ensure,
modifier conditions, singleton classes, methods, or expression wrappers
are unsupported. Even an unconditional begin wrapper is unsupported.
Or/and/operator writes, multiple assignment targets, dynamic RHS,
ternary RHS, calls, and Class.new MUST NOT become resolved aliases.
Named unsupported writes enter the inventory so relevant identities can
warn and conflicts cannot be hidden. const_set/autoload/const_missing
remain outside alias discovery.

## Selected binding inventory and graph

During the existing Prism traversal, record selected-source class/module
declarations and named writes, plus alias candidates. Presence facts in
DefinedConstantIndex MUST remain separate from alias graph facts.
Exactly one supported alias binding and no other binding to its LHS is
required. Duplicate aliases, even identical ones, alias plus class/module,
or alias plus unsupported writes produce alias_binding_conflict. No
source-order winner is selected. Existing reopened direct class fragments
are allowed and merged as before; they are not conflicts by themselves.
An alias that reaches a conflicting binding MUST remain unknown.
Selected ambiguous constant paths also retain leaf-name conflict evidence:
an assignment or declaration such as `self::OldJob = OtherJob` cannot be
ignored when its leaf may affect an alias or a reached terminal. These
facts conservatively block resolution without evaluating the receiver.
Excluded or differently named ambiguous facts do not enter this proof.

Each revision resolves its own graph independently. Finite chains have
no arbitrary length cap. Iterative traversal detects cycles without
recursive stack overflow. Resolved chain order follows edges, for example
`[OldJob, MiddleJob, NewJob]`. A cycle chain closes with its repeated
identity, for example `[OldJob, MiddleJob, OldJob]`. A missing or
unrecognized terminal is alias_target_unresolved. Failed suffixes
propagate their reason and proof to aliases depending on them.

Only selected files supply trusted edges. Excluded declarations/writes
may block absence through the presence pass, but MUST NOT resolve aliases.
An excluded OldJob alias yields outside_analysis_scope for a removal
transition; a selected alias targeting an excluded worker yields
alias_target_unresolved. File movement alone does not alter identity
compatibility. All keys preserve Prism's exact UTF-8 codepoints.

## Effective consumers and relevant identities

Snapshot workers remain directly recognized workers. An effective
consumer map resolves serialized identity S to either direct worker S or
the terminal contract of supported alias S. A conflicting alias masks an
otherwise recognized direct consumer at the same identity. Resolved
aliases retain resolution status even when the terminal signature is
unknown (keyword_parameters, missing_perform, multiple_perform_definitions).
Effective alias contracts carry every edge location and the terminal's
declaration/include/perform proof. No new location role is introduced.

Comparison identities MUST include all direct workers in either revision,
all resolved BASE aliases (historical queues may retain their names),
aliases present in both revisions, aliases matching an opposite direct
worker, and aliases referenced by visible producers or needed to explain
unknown producer identity. A dormant HEAD-only alias is not automatically
a worker result or standalone warning. The full graph may still be built.
The common-alias criterion refers to constant-to-constant candidates,
including unsupported static forms; unrelated dynamic/literal writes such
as VERSION = "1" do not become relevant merely by existing in both
revisions. They still block conflicting bindings and are diagnosed when
referenced by a producer or matched to an opposite worker identity.

## Producer resolution

Class-object resolution first performs existing lexical/root lookup in
the producer's own snapshot, including alias bindings. A resolved alias
normalizes to its terminal direct identity. An unknown alias MUST NOT
guess its syntactic name as a serialized identity. Such a call retains a
separate attributed alias name for diagnostics and comparison relevance,
but cannot drive JC005. Existing cross-revision non-alias attribution
remains available only when no local alias/binding narrows that proof.
When alias lookup applies, a nearer selected non-worker class/module
binding stops fallback and leaves producer identity unknown. Opposite
revision names cannot override a selected local binding. Normalized
Class-object alias producers retain edge and terminal declaration,
include, and perform locations; unresolved targets retain any selected
declaration that prevents recognition.

Exact-string resolution remains exact and does not canonicalize aliases.
Producer identity certainty and arity certainty MUST be distinct:
resolved alias plus `*args` retains the terminal identity and splat_arguments;
unknown alias plus literal args retains unknown identity. Known identity
with unknown arity can still drive JC005. Existing Hash source-order,
dynamic-key, bulk-row, lexical producer, and Client String rules persist.

## Rules, unknown reasons, and proof

JC001: old serialized payload accepted by BASE but rejected by HEAD,
including alias consumers. JC002: HEAD accepted payload rejected by BASE,
under its serialized identity. JC003: HEAD producer/consumer mismatch.
JC001 owns a repeated HEAD mismatch at the same identity/arity before
JC003. JC001 OldJob and JC003 NewJob from a Class alias producer remain
distinct findings. JC006 narrowing/witness precedence remains unchanged.

JC004 requires absence of a BASE effective serialized identity in HEAD.
A resolved alias blocks removal; a relevant unknown alias warns rather
than passing or proving absence. Removing a BASE resolved alias can cause
JC004 even if its terminal still exists. JC005 requires HEAD known
serialized producer identity with an effective HEAD consumer and proven
BASE absence, conditional on old processes consuming that queue. An
exact-string alias producer can cause JC005 for the alias; a Class-object
alias producer can cause JC005 only for the terminal. BASE resolved aliases
block absence; unresolved aliases warn. Existing presence budget/error
behavior and conservative absence proof remain frozen.

JC007 adds exactly four reasons: alias_target_unresolved (supported edge
does not reach a recognized worker), alias_cycle, alias_binding_conflict,
and unsupported_alias_assignment. Existing contract/arity reasons retain
their meanings. Alias warning messages describe the unresolved binding
and risk to the persisted identity; remediation suggests an explicit
static alias only if it matches runtime behavior, or manual inspection.

BASE alias uncertainty affects head_to_base. HEAD alias uncertainty affects
base_to_head and additionally head_to_head only with a HEAD producer for
that same serialized identity. A Class call normalizing to another name
does not manufacture head_to_head for its source alias. Alias evidence
fingerprints contain reason, exact identity, lexical scope, normalized
assignment/enclosing tokens, target reference, and structural chain, but
exclude revision, paths, lines, and columns. Stable binding/occurrence
ordering preserves distinct evidence and cross-revision aggregation.

## JSON schema 3 and determinism

workers[] now represents compared serialized identities, sorted by exact
name. Every result has base_alias and head_alias, null for a direct or
absent binding, otherwise an object with exactly status, target, chain,
unknown_reason. Resolved status has terminal target and null reason;
unknown status has null target and its alias reason. Conflict or unsupported
assignment chains start with the alias alone; unresolved target chains
include the missing target, and cycle chains close the cycle.

Presence values are recognized_worker, resolved_alias,
defined_unrecognized, outside_scan_scope, absent, unverified, not_checked.
Unknown aliases use defined_unrecognized even in a direct binding conflict.
Effective contracts appear in base_contract/head_contract for resolved
aliases; unresolved aliases have null contracts. Producer arities and
matrix statuses use known serialized identity and effective consumers.
summary.workers continues to count direct worker facts only, never aliases.
Suppressions match the finding's exact serialized worker identity.

Inputs and graph processing use stable sorting. Chains follow structural
edge order. Repeated text/JSON for identical refs/config/toolchain MUST be
byte-identical, including cycles, conflicts, and Unicode names.

## Boundaries and acceptance

Recognition assumes normal successful application boot, as direct worker
recognition already does; it does not prove file load order or Zeitwerk
behavior. No general constant evaluator/dataflow, inheritance/concerns,
source execution, Rails/Sidekiq boot, Redis/network access, keyword
compatibility, value/Hash schema analysis, ActiveJob, Client instances,
wrappers, queue/feature-flag simulation, manual alias config, heuristic
rename detection, JC008, SARIF, --explain, or coverage report is added.

Acceptance requires supported AST/context and namespace tests, finite and
cross-file graph tests, cycles/conflicts/unknown terminals, reopened and
unknown-contract targets, all Class-object and exact-string producer
families, separate identity/arity uncertainty, every JC rule and precedence,
staged rename and alias removal, excluded-source presence proof, exact
Unicode/suppression behavior, schema 3 (success and failure), unchanged
config version 1, deterministic output, existing regressions, source
non-execution/worktree/index immutability, offline tests, gem packaging,
isolated CLI install/scenarios, and full validation in UTF-8 locale.
Locally unavailable Ruby 3.3/4.0 matrix entries remain official CI work.
The implementation phase MUST leave an uncommitted candidate and MUST NOT
commit, push, tag, release, publish, or alter historical v0.2.1 artifacts.
