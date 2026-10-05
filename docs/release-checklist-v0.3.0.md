# jobcompat v0.3.0 release checklist

This document prepares jobcompat v0.3.0 for release. Checked boxes record completed preparation evidence. Unchecked boxes are final tag, publication, GitHub Release, or post-publication gates. This preparation does not authorize creating or pushing `v0.3.0`.

**Pushing `v0.3.0` triggers the Release workflow and may publish the gem to RubyGems. Treat tag push as a publication action.**

## Release identity

- Repository: `cottondesu/jobcompat`, branch `main`.
- Gem and CLI version: `0.3.0`; intended annotated tag: `v0.3.0`.
- Intended release date: `2026-10-05`. If execution is delayed and publication is no longer intended for this date, update the release date consistently before committing or tagging; never backdate publication.
- JSON schema: `3`; `.jobcompat.yml` configuration schema: `1`.
- Ruby: `>= 3.3`; Prism: `>= 1.9, < 2`; no new runtime dependencies.
- Implementation commit: `642e2c4c838db78d4e7ae6dd9ff3b958b6336483` (`Add worker rename alias compatibility`), parent `6f6c2deecad10111d70455dd343e1f89a3af088c`.
- Implementation CI: run `37302967087`.
- Release candidate SHA: determined by this preparation commit; record the exact SHA and its exact CI run in the final preparation report. The release-preparation commit, not the implementation commit, must become the eventual tag target if its exact CI passes.

## Reviewed implementation

- [x] Fresh independent review: SHIP; 0 BLOCKER and 0 MAJOR.
- [x] Final checked-in suite baseline: 189 tests, 1,942 assertions, 0 failures, 0 errors, 0 skips.
- [x] Reviewer documentation MINOR resolved before the implementation commit.
- [x] Analysis does not execute source, boot Rails or Sidekiq, or connect to Redis.

## Implementation CI evidence

Implementation commit `642e2c4c838db78d4e7ae6dd9ff3b958b6336483` passed GitHub Actions run `37302967087`:

- [x] Ruby 3.3 tests and gem build succeeded.
- [x] Ruby 3.4 tests and gem build succeeded.
- [x] Ruby 4.0 tests and gem build succeeded.

This implementation CI does not replace the required official CI on the release-preparation commit.

## Release-only local validation

- [x] `LANG=C.UTF-8 bundle exec rake test` under Ruby 3.4.8 / Prism 1.9.0: 189 tests, 1,942 assertions, 0 failures, 0 errors, 0 skips.
- [x] `git diff --check` passes.
- [x] `gem build jobcompat.gemspec` succeeds; package inspected and generated `.gem` removed after inspection.
- [x] Both v0.3.0 release documents are packaged under the existing `docs/*.md` gemspec policy; package contains no generated or local tooling files.
- [x] Installed the candidate gem into a fresh isolated destination; `jobcompat --version` prints `jobcompat 0.3.0`.
- [x] The full suite and alias integration scenarios verify safe alias 0, JC001 1, JC005 1, warning-only alias uncertainty 0, invalid config 2, and invalid ref 2.
- [x] Alias integration scenarios verify safe alias resolution, Class-object producer identity, exact Client String identity, and schema 3 fields; product tests were not changed.

## Publication prerequisites

- [ ] Manually confirm GitHub environment `release` exists, its required reviewer/protection is intact, and its tag deployment rule remains acceptable. Do not weaken the environment.
- [ ] Manually confirm the RubyGems Trusted Publisher for `jobcompat` matches owner `cottondesu`, repository `jobcompat`, workflow `release.yml`, and environment `release`. Do not introduce a long-lived RubyGems API key.

## Public-state precheck (2026-10-05)

- [x] RubyGems lists `0.2.1`, `0.2.0`, and `0.1.0`; `0.3.0` is absent.
- [x] The local `v0.3.0` tag is absent; remote tags include `v0.2.1` and no `v0.3.0`.
- [x] GitHub Releases include `v0.2.1`, `v0.2.0`, and `v0.1.0`; `v0.3.0` is absent.
- [x] Historical `v0.2.1` annotated tag object is `b9ca1f7a3d0818ee23beff48907cb3d6a2e0eb1c`, peeled commit is `6f6c2deecad10111d70455dd343e1f89a3af088c`, and the GitHub Release and RubyGems version are present.
- [ ] Immediately before final release execution, repeat all v0.3.0 absence checks. Stop if any already exists; never overwrite it.

## Release workflow audit

The inspected `.github/workflows/release.yml` is unchanged. It triggers on tag pushes matching `v*`; the Ruby 3.3 / 3.4 / 4.0 test matrix gates `publish` through `needs: test`. Publication runs on Ruby 4.0 in environment `release`, grants GitHub OIDC `id-token: write`, checks tag/version and public metadata, configures RubyGems credentials with `rubygems/configure-rubygems-credentials`, then runs `gem push`.

- [x] Workflow trigger, test matrix, publish dependency, Ruby version, environment, OIDC permission, tag/version gate, metadata gate, and publication command audited.
- [ ] Confirm the GitHub release environment and RubyGems Trusted Publisher manually before the final tag action.

## Release-note examples and content

- [x] Release notes were compared with `docs/spec-v0.3.md`, `README.md`, implementation, and tests for alias resolution, Class-object normalization, exact Client Strings, JC004/JC005, JC007 reasons, schema 3 fields, and config schema 1.
- [x] The alias integration scenarios and full local suite passed against the unchanged candidate implementation.

## Tag gate

**Pushing `v0.3.0` triggers the Release workflow and may publish `jobcompat 0.3.0` automatically. Treat tag push as a publication action.** Before any separately approved final release execution:

- [ ] Release-preparation commit is fixed and its exact SHA identified.
- [ ] Exact release-preparation SHA has green official CI, including Ruby 3.3, Ruby 3.4, and Ruby 4.0.
- [ ] GitHub `release` environment gate has been manually verified.
- [ ] RubyGems Trusted Publisher settings have been manually verified.
- [ ] RubyGems `0.3.0`, local and remote `v0.3.0` tags, and GitHub Release `v0.3.0` are still absent.
- [ ] Separate final release execution approval has been obtained.

## Future tag requirements

Documented for the separately approved release-execution phase; do not perform during preparation:

- Create an annotated `v0.3.0` tag pointing exactly to the verified release-preparation commit, not `642e2c4c838db78d4e7ae6dd9ff3b958b6336483`.
- Never create a lightweight tag, force a tag, or move an existing tag.

## Release workflow verification

- [ ] Release workflow triggered by `v0.3.0`.
- [ ] Workflow tag resolves to the approved release-candidate SHA.
- [ ] Ruby 3.3, Ruby 3.4, and Ruby 4.0 test jobs succeed.
- [ ] Publish job starts only after tests; environment approval succeeds.
- [ ] Tag/version and metadata gates succeed.
- [ ] Publish-job tests and gem build succeed.
- [ ] OIDC credentials setup and gem push succeed.
- [ ] RubyGems publicly lists version `0.3.0`; do not infer publication solely from workflow status.

## Post-publication

- [ ] Verify RubyGems version `0.3.0`, Ruby `>= 3.3`, Prism `>= 1.9, < 2`, metadata URLs, and package contents.
- [ ] Install from public RubyGems in a fresh environment and verify `jobcompat --version`.
- [ ] Run representative CLI checks against the installed public gem.
- [ ] Create or verify GitHub Release `v0.3.0` using the reviewed release notes and confirm it points to the correct tag.
- [ ] Record the release workflow URL.

## Rollback

Do not overwrite or reuse `0.3.0`, move `v0.3.0`, or rewrite existing release history after publication. Fix forward with a later version. If a published gem must be removed, follow the official [RubyGems yank procedure](https://guides.rubygems.org/removing-a-published-gem/); yanking does not remove copies already installed.
