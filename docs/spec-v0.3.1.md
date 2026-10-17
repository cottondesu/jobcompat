# jobcompat v0.3.1 delta specification

Status: normative for 0.3.1. This document extends `spec-v0.3.md` (which extends
`spec-v0.2.1.md`, `spec-v0.2.md`, and `spec-v0.1.md`) with the optional text
`--explain` output. It adds display capability only. It changes no
compatibility decision, JSON contract, or exit status policy.

## Version and schema contracts

Gem and CLI version: 0.3.1. Completed and failed JSON envelopes continue to
use `schema_version: 3` with the same fields and ordering as 0.3.0.
`.jobcompat.yml` continues to use config version 1. Ruby >= 3.3 and
prism >= 1.9, < 2 are unchanged, and no runtime dependency is added.

JC001–JC007 semantics, severities, comparison directions, finding precedence,
finding deduplication, semantic fingerprints, producer identity resolution,
alias resolution, presence budget, suppression matching, and exit status
policy are unchanged.

## CLI contract

`jobcompat check --base REF --explain` is accepted, as are
`--format text --explain` and `--explain --format text` in either order.
Option order must not change results.

`--format json --explain` (either order) is rejected before any Git or
parse work: exit 2, category `config_error`, message
`--explain is supported only with --format text`, and the regular JSON
failed envelope with `schema_version: 3` on stdout. No stack trace or
internal exception reaches stderr.

`check --help` lists `--explain` with the description
`Explain the evidence behind each finding (text only)`. Top-level
`--help` and `--version` output is unchanged except the version string.

All existing failure categories (config_error, parse_error, Git errors,
internal_error) keep their existing streams, exit code 2, diagnostics
sanitization, and produce no Explain-specific additional diagnostics.

## Explain scope

`--explain` explains only public findings that remain after targeted
suppression. Suppressed finding bodies receive no explanation. Internal
unreported candidates, producers that never became findings, repository
coverage, runtime queue contents, and hypothetical dynamic producers are out
of scope. Suppression audit lines, counts, order, and reasons are unchanged.

When no findings remain, the existing PASS (or PASS WITH WARNINGS) output is
emitted with no Explanation heading or section.

## Rendering contract

For each remaining finding, an Explanation section is inserted between the
finding's source location list and `Suggested migration:`. All pre-existing
lines (severity, rule ID, worker, message, Revisions, Reason, Affected
directions, Risk, locations, remediation, summary, suppression audit) keep
their content, order, indentation, newlines, and trailing newline. The
section uses fixed headings:

```text
  Explanation:
    Evidence:
    Decision:
    Boundary:
```

`Evidence` contains one or more verified facts used by the decision.
`Decision` states the rule that produced the finding. `Boundary` states what
the evidence cannot prove, including conditional assumptions. Each finding
receives at most one Explanation. Every line passes the existing
`Formatter.safe_line` sanitization.

Without `--explain`, text output is byte-for-byte identical to 0.3.0 apart
from the version string, and JSON output is byte-for-byte identical to 0.3.0
apart from `tool.version`.

## Per-rule explanation obligations

Each Explanation is built from the facts the Engine actually used at the
finding site.

- JC001: BASE producer's decided payload arity, the BASE consumer acceptance,
  the HEAD consumer rejection, and—if `head_to_head` is among the
  directions—a HEAD producer witness of the same arity. No HEAD witness is
  claimed when the direction is absent. Boundary: retained queue contents are
  not inspected.
- JC002: HEAD producer's decided arity, HEAD consumer acceptance, BASE
  consumer rejection. Boundary: whether an old process consumes the relevant
  queue, and when it retires, is not statically determined.
- JC003: HEAD producer arity and HEAD consumer rejection only; unrelated
  base-revision evidence must not appear. JC001/JC003 precedence is
  unchanged.
- JC004: BASE-recognized serialized identity, the conservative HEAD absence
  proof, and provenance. `defined_unrecognized`, `outside_scan_scope`, and
  `unverified` presence statuses are never described as absence. Boundary:
  static absence does not mean the queue is empty.
- JC005: the decided HEAD serialized identity, HEAD recognition, and the
  BASE absence proof. The rolling-deploy failure is conditional on an old
  process consuming the relevant queue; it is never stated as unconditional.
  A known producer identity suffices when payload arity is unknown. A
  Class-object alias producer is explained under its terminal serialized
  identity, and an exact Client String identity is never rewritten.
- JC006: BASE contract, HEAD contract, the removed acceptance ranges, and
  the absence of a qualifying producer witness. Boundary: missing producer
  witnesses do not prove absence of queued, scheduled, retried, historical,
  or externally enqueued payloads; no safety or compatibility claim is made.
- JC007: the existing `unknown_reason`, revision(s), direction(s), and the
  source provenance used for the diagnosis. Unknown or unsupported evidence
  is never presented as proof of compatibility. No new unknown reason is
  introduced. The alias reasons `alias_target_unresolved`, `alias_cycle`,
  `alias_binding_conflict`, and `unsupported_alias_assignment` are reported
  as-is, and an undetermined alias terminal is never presented as resolved.

## Alias semantics

Serialized identity rules follow 0.3.0. A Class-object producer through an
alias serializes as the terminal Class name; an exact Client String keeps
its exact identity. Explanation text never substitutes a source alias token
for a serialized identity or vice versa.

For findings whose evidence involves an alias, Explanation may include one
line per relevant revision, using only the existing `AliasResolution`
result:

```text
Alias (HEAD): OldJob -> MiddleJob -> NewJob (resolved).
Alias (HEAD): unresolved (alias_cycle).
```

The Engine never re-walks the alias graph for explanations.

## Proof model and isolation

Explanations are produced by the Engine at the sites where findings are
decided, using the producer groups, consumer contracts, presence results,
alias resolutions, and unknown roots already computed. Re-running
`Contract#accepts?`, re-walking alias graphs, re-proving absence,
re-extracting producers, or parsing finding messages to recover evidence is
prohibited.

The Engine exposes `evaluate(with_explanations: false)`. The default return
value is unchanged. With `with_explanations: true` the result additionally
carries an internal explanation sidecar keyed by finding object identity, so
multiple findings of the same rule and worker, JC007 deduplication groups,
and post-suppression survivors remain correctly paired. Object identity is
internal only; no identifier is printed or serialized. Findings and worker
rows never gain an `explanation` key, and the sidecar never reaches JSON.

`Formatter.text(envelope, explanations: nil)` renders the section only when
a non-nil sidecar maps the finding. `explanations: nil` keeps output
byte-identical. `Formatter.json` is unchanged.
Suppression continues to run after evaluation and before formatting;
explanations are displayed only for surviving findings.

Call-site counts in Evidence count distinct enqueue locations, keyed by
revision, path, line, and column. Location role is not part of that identity,
worker declarations and alias assignments are never counted, and multiple
arities or known/unknown records originating from one enqueue location count
once, so one bulk enqueue with several rows is one call site.

## Determinism and security

For the same repository state, configuration, and command, repeated runs
produce byte-identical stdout, byte-identical stderr, and identical exit
codes, with and without `--explain`. Explanation construction avoids
insertion-order dependence, uses the existing stable location and chain
ordering, emits no timestamps, randomness, object IDs, or absolute temporary
paths, performs no Unicode normalization, and cannot inject raw newlines,
ANSI escapes, or Unicode format controls (existing `safe_line` escaping
applies). Error-path secret sanitization and stdout/stderr responsibilities
are unchanged.

## Test acceptance criteria

- CLI: `--explain` accepted alone and with `--format text` in both orders;
  `--format json --explain` rejected with exit 2, `config_error`, schema 3
  failed envelope; help lists `--explain`; help/version unchanged; invalid
  config, invalid ref, and parse errors keep existing failure contracts.
- JC001–JC007: per-rule evidence content, precedence, absence conservatism,
  conditional rolling-deploy wording for JC005, no empty-queue claims for
  JC006, unknown-not-compatible for JC007.
- Alias: resolved BASE/HEAD chains, finite chains, unsupported and unknown
  aliases, direct workers, and Class-object versus exact String contrast.
- Suppression: suppressed findings receive no Explanation; surviving
  findings do; audit unchanged.
- Backward compatibility: default text byte-identical to 0.3.0 fixtures
  except the version string; JSON identical except `tool.version`;
  normalized comparison must not mask findings, summary, provenance, or
  unknown reasons.
- Determinism/security: double-run stdout/stderr/exit equality, control
  characters, ANSI escapes, Unicode format controls, Unicode worker names,
  newlines in refs, dirty worktree neutrality, no source execution, no
  network.
- No findings: exit 0 with no added Explanation output; warning-only exit 0;
  any errors exit 1.

## Non-goals

No new compatibility rule, severity, direction, unknown reason, JSON field,
config key, dependency, queue/runtime simulation, heuristic rename
detection, or change to existing normative specifications. Explanations do
not restate suppressed findings and do not estimate runtime behavior.
