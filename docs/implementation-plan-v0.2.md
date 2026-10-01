# jobcompat v0.2 implementation plan

Status: implemented

## Delivery sequence

1. Reconfirm the public Sidekiq Job/Setter and Client producer shapes from upstream source and documentation.
2. Extend syntax extraction while keeping the existing `Call` fact and compatibility engine semantics.
3. Share one pure bulk-arity extractor across worker, Setter, and Client bulk calls.
4. Add exact-string versus lexical-constant Client target resolution and explicit v2 uncertainty reasons.
5. Raise the gem version to 0.2.0 and JSON schema to 2 while leaving config version 1.
6. Add unit coverage for AST shapes, deduplication, mixed known/unknown rows, options, false positives, and 1,000-row fact bounds.
7. Add temporary-Git integration coverage for JC001, JC002, JC003, JC005, JC006 witness behavior, JC007, schema v2, and byte determinism.
8. Synchronize README, architecture, changelog, and this normative delta specification.
9. Run the full suite, syntax checks, gem build/contents/install, CLI and exit-code smoke scenarios, and diff review.

## Scope boundaries

The compatibility rules and their precedence are not changed. No Sidekiq dependency, dataflow, source execution, Client instance inference, wrapper inference, ActiveJob support, keyword compatibility, payload type/schema analysis, or release operation is added.

## Verification inventory

- Existing v0.1 suite remains green.
- Bulk extraction covers known, duplicate, zero-argument, empty, dynamic, mixed, splat, option, namespace, root-qualified, safe-navigation, and large-literal cases.
- Setter scheduled calls exclude their schedule argument.
- Client tests cover exact receivers, constant and String classes, empty and multi-argument payloads, options, dynamic/missing shapes, per-key final-write certainty for splats and dynamic keys, duplicate explicit keys, mixed splat/dynamic ordering, parentheses, and non-Sidekiq receivers. BASE/HEAD guards prove unknown class evidence cannot create JC005, while known class / unknown args still can, for both `push` and `push_bulk`.
- Client String validation reuses Prism's constant syntax and the existing constant extractor. Tests cover decomposed Unicode and qualified names, exact namespace matching, distinct precomposed/decomposed identities, non-canonical complete inputs, valid source encodings, and invalid bytes that warn without crashing. Both Client APIs exercise Unicode JC001/JC002/JC003/JC005 and deterministic Unicode/unsupported output.
- Integration tests prove new producer facts flow through JC001–JC007 without a new rule.
- Repeated text and JSON outputs are byte-identical.
