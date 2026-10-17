# jobcompat v0.3.1 implementation plan

Baseline: `02751a57e21da3f548f6d6442b17a438026ef9e1` (v0.3.0). All changes
stay uncommitted for independent review.

## Change order

1. `lib/jobcompat/explanation.rb` (new): `Explanation = Data.define(:evidence, :decision, :boundary)` plus a private builder module used by the Engine. Evidence entries, decision, and boundary are plain frozen strings; rendering responsibility stays with the Formatter.
2. `lib/jobcompat/engine.rb`: `evaluate(with_explanations: false)`. At each
   finding site (JC001, JC002, JC003, JC004, JC005, JC006, presence-unknown
   JC007, and the aggregated JC007 roots) build an `Explanation` from the
   producer group, contracts, presence result, alias resolution, and unknown
   root already in scope, and store it in a
   `{}.compare_by_identity` sidecar keyed by the finding hash object. The
   sidecar is returned as `explanations:` only when requested. Finding and
   worker rows are not modified.
3. `lib/jobcompat/formatter.rb`: `text(envelope, explanations: nil)`. When a
   non-nil sidecar maps the finding, render the fixed `Explanation:` /
   `Evidence:` / `Decision:` / `Boundary:` block between the location lines
   and `Suggested migration:`. `explanations: nil` keeps output
   byte-identical. `json` untouched.
4. `lib/jobcompat/cli.rb`: parse `--explain` (default false); reject
   `--explain` with non-text format as `config_error` before repository
   access; pass `with_explanations:` to `evaluate` and `explanations:` to
   `Formatter.text` for the completed text path only.
5. `lib/jobcompat/version.rb` -> 0.3.1; `Gemfile.lock` path spec version.
6. `docs/spec-v0.3.1.md` (normative delta), this plan, README quick-start and
   explanation notes, `CHANGELOG.md` `## 0.3.1 - Unreleased`.

## Test order

1. Unit `test/unit/explanation_test.rb`: Explanation VO shape; formatter
   parity (nil sidecar byte-identical, unknown finding -> no section);
   sanitization of hostile strings.
2. Integration `test/integration/explain_command_test.rb`: CLI contract
   (accept/combos/order/json rejection/failed envelope schema 3/help);
   per-rule content for JC001 (both direction variants, alias-carried
   identity), JC002, JC003 (no base leakage), JC004 (absence only;
   outside-scope fixture must not claim absence), JC005 (conditional
   rolling-deploy wording, Class-object terminal identity, exact Client
   String identity), JC006 (no empty-queue claim), JC007 (alias cycle,
   unresolved, splat producer, keyword contract); suppression behavior;
   zero-finding behavior; determinism double-run; default-output regression
   against committed expectations derived from the frozen 0.3.0 baselines.
3. Full suite `rake test`; baseline runner `compare` (byte-identical after
   version normalization only).
4. `gem build`, package content inspection, isolated install, CLI smoke.

## Regression evidence

Frozen 0.3.0 outputs for JC001–JC007 (including alias-carried, client-string,
and outside-scope variants), resolved alias rename, targeted suppression, and
a no-findings comparison were captured before implementation and are
re-compared after; only the version string may differ.
