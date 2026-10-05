# v0.3.0 implementation plan

Implement the normative delta in spec-v0.3.md in this order.

1. Extend Analyzer's existing Prism pass with immutable AliasCandidate and
   ConstantBinding facts. Propagate a narrow direct-statement context for
   alias proof, while retaining baseline worker/producer discovery. Keep
   DefinedConstantIndex responsible only for conservative presence.
2. Build AliasResolver from selected binding inventory and direct workers.
   Reuse one constant candidate helper. Iterate each chain with cycle
   detection; reject duplicate/conflicting bindings and unsupported edges.
   Retain deterministic chain, locations, and revision-free fingerprints.
3. Extend RevisionSnapshot with aliases and effective consumer/presence
   helpers. Preserve workers as direct facts and summary counts. Derive
   alias contracts from terminal contracts with complete proof locations.
4. Resolve producers using snapshot-local alias semantics. Keep identity
   certainty separate from arity certainty and diagnostic attribution.
   Preserve exact Client Strings and baseline non-alias attribution.
5. Feed relevant serialized identities and effective consumers into Engine.
   Keep JC001-JC007 logic and precedence; add alias warnings/metadata and
   update identity wording. Emit schema 3 on completed and failed CLI output.
6. Add focused AST/graph/producer unit tests and temporary Git rule,
   deployment, JSON, determinism, Unicode, suppression, and security tests.
   Update only intentional version/schema expectations in existing tests.
7. Update README, architecture, changelog, version and lockfile. Run all
   tests in available Ruby with UTF-8 locale, build and inspect the gem,
   install into a temporary isolated destination, run CLI exit scenarios,
   inspect the full diff, and remove only the generated package.

Mandala tracks specification, aliases, producers, compatibility, validation.
Only evidence-backed completed facets are marked done. No release operation
is part of this plan.
