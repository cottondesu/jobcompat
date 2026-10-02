# jobcompat v0.2.1 release checklist

This is preparation for a maintenance update to the already published `jobcompat` gem. Checked boxes record completed preparation checks; unchecked boxes are final release or post-publication gates, not claims of completion. No v0.2.1 tag or publication is authorized by this document.

## Release identity

- Repository: `cottondesu/jobcompat`, branch `main`.
- Gem version: `0.2.1`; intended annotated tag: `v0.2.1`.
- Intended release date: `2026-10-02`. If execution is delayed, reconcile the CHANGELOG date with the actual intended date before tagging; never backdate publication.
- JSON schema: `2`; `.jobcompat.yml` configuration schema: `1`.
- Implementation commit: `fd6d138f229228be8801de9a7ae040cab21c9923` (`Fix Unicode worker suppression validation`), on top of the v0.2.0 release commit `378203731bcc0e4a06a1a3550fbd5605d9760f2e`.
- Implementation history note: the implementation was first pushed as `0397dc5b7b8eb4acaa975d8d3b628aa4f87aed8a`. At the maintainer's request, before any tag or publication, it was replaced once on `main` by `fd6d138` to correct the commit author and committer and remove a co-author trailer. Both commits have the identical tree `18602325cc75951aee1d078c92c4c7813443f570`, so the reviewed product bytes are unchanged. `0397dc5` is no longer on `main` and must not be tagged.
- Release candidate commit: to be determined after the `Prepare v0.2.1 release` commit. Record its exact SHA and CI run in the final release execution record; do not select a moving `main` ref without verification.

## Reviewed implementation

- [x] Fresh independent review of the complete v0.2.1 diff: verdict SHIP, no BLOCKER, no MAJOR.
- [x] Independent validation: 140 tests, 1298 assertions, 0 failures, 0 errors, 0 skips with Prism 1.9.0 under a UTF-8 locale, on Ruby 3.3.6 (reviewer environment), Ruby 3.4.8 (conda-forge build), and Ruby 4.0.6 (conda-forge build). Official GitHub CI below is the release authority.
- [x] Reviewer MINOR, test-only: under a POSIX / US-ASCII locale, the Unicode suppression text assertion in `test/integration/check_command_test.rb` raises `Encoding::CompatibilityError` in the test itself. Production output is byte-identical between UTF-8 and POSIX locales; no production locale regression was observed. Non-release-blocking; deferred past v0.2.1 and intentionally left unchanged in this release. Canonical local validation uses a UTF-8 locale.

## Automated validation

- [x] Implementation commit `fd6d138` passed [CI run 36992116824](https://github.com/cottondesu/jobcompat/actions/runs/36992116824): Ruby 3.3.12, 3.4.10, and 4.0.6 PASS; each ran 140 tests / 1298 assertions with 0 failures, errors, and skips and built `jobcompat-0.2.1.gem`. (Superseded commit `0397dc5` had passed [CI run 36990271965](https://github.com/cottondesu/jobcompat/actions/runs/36990271965) with the same tree.)
- [x] Candidate local `LANG=C.UTF-8 bundle exec rake test` on Ruby 3.3.6 / Prism 1.9.0: 140 tests, 1298 assertions, zero failures, errors, and skips.
- [x] Candidate `git diff --check` and release-only diff review pass; only `CHANGELOG.md` and the two v0.2.1 release documents change, and product bytes match the implementation commit.
- [x] Build the candidate Gem and inspect its entries, including `lib/jobcompat/canonical_worker_name.rb`, the v0.2.1 spec and implementation plan, and both v0.2.1 release documents. No local tooling state, credentials, caches, scratch files, patches, review files, or nested Gems are included.
- [x] Install the candidate Gem into a fresh isolated destination under a UTF-8 locale; `jobcompat --version` reports `jobcompat 0.2.1`; clean 0, compatibility error 1, warning-only 0, invalid config 2, invalid ref 2, and Unicode suppression 0 pass.
- [x] Release-note examples checked with the installed candidate and Prism 1.9.0: a `ÁJob` (`A` + `U+0301` + `Job`) suppression is valid, `管理::輸出` is a `config_error` with exit 2, and `Job管理::E輸出` is valid.
- [ ] Record the pushed release-preparation SHA and its CI run; require Ruby 3.3, 3.4, and 4.0 success, including the Gem build step, on that exact SHA before tagging. The implementation run above does not substitute for candidate CI.

## Compatibility note

- [x] The v0.2.1 release notes state prominently that v0.2.0 could silently accept `ignore[].worker` names that are not Ruby constant names, that such entries could never match a finding under the canonical worker-name semantics, and that v0.2.1 rejects them as `config_error` with exit 2.
- [x] The note explains why `管理::輸出` is rejected (not a Ruby constant path) and shows that CJK constant paths such as `Job管理::E輸出` remain accepted.
- [x] The v0.2.0 limitation about combining-mark suppressions is not repeated, because v0.2.1 fixes it.

## Publication prerequisites

- [x] On 2026-10-02, public RubyGems listed `0.1.0` and `0.2.0` and no `0.2.1`.
- [x] On 2026-10-02, local and remote tags were `v0.1.0` and `v0.2.0` only, and GitHub Releases contained `v0.1.0` and `v0.2.0` and no `v0.2.1`.
- [ ] Confirm GitHub environment `release` still exists, requires reviewer `cottondesu`, and permits tag pattern `v*`. The preparation tooling could not read environment settings, so this is a manual gate. Do not weaken these protections.
- [ ] Confirm the current RubyGems Trusted Publisher for `jobcompat` in the maintainer UI: owner `cottondesu`, repository `jobcompat`, workflow file `release.yml`, environment `release`. Public package metadata and earlier publications are not proof of the current publisher settings. Do not introduce a long-lived RubyGems API key. See [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).
- [x] Release workflow retains the tag/version and public metadata gates. Gem homepage, source, changelog, and issue URLs refer to `cottondesu/jobcompat`.
- [x] Review the v0.2.1 release notes against the normative scope and inspect the built candidate package.
- [ ] Immediately before release execution, recheck that `0.2.1` is absent on RubyGems and `v0.2.1` is absent locally, remotely, and in GitHub Releases. Stop if any already exists; never overwrite it.

## Tag gate

**Pushing `v0.2.1` triggers the Release workflow and may publish the Gem automatically. Treat tag push as a publication action.**

- [ ] Complete every pre-tag validation and publication prerequisite above, including the manual environment and Trusted Publisher checks and exact candidate CI.
- [ ] Obtain separate final release execution approval. Release preparation alone does not authorize tagging or publication.
- [ ] Confirm the exact release candidate SHA, product version, intended release date, and unchanged v0.1.0 and v0.2.0 release identities.
- [ ] Under that separate approval, create an annotated `v0.2.1` tag on the verified SHA and push only that tag. Do not force or push unrelated tags.

## Release workflow verification

The unchanged `.github/workflows/release.yml` triggers on pushes matching `v*`. Its Ruby 3.3 / 3.4 / 4.0 tests precede the `publish` job through `needs: test`. Publication uses Ruby 4.0, environment `release`, GitHub OIDC `id-token: write`, the tag/version and public metadata checks, pinned `rubygems/configure-rubygems-credentials`, and `gem push`.

- [ ] Verify the triggered Release run refers to the approved tag and exact candidate SHA.
- [ ] Confirm all three test jobs pass and the publication environment approval is satisfied.
- [ ] Confirm `GITHUB_REF_NAME == "v#{Jobcompat::VERSION}"`, public metadata checks, publication-job tests, build, credentials setup, and push all succeed.
- [ ] Confirm RubyGems lists `jobcompat` version `0.2.1`; do not infer publication solely from a tag or a partial workflow result.

## After publication

- [ ] Check RubyGems version, ownership, Ruby/dependency requirements, public URLs, and package contents.
- [ ] Install `jobcompat` 0.2.1 from RubyGems in a clean environment; verify version/help and representative CLI checks.
- [ ] Under the separate release approval, create or verify the GitHub Release for `v0.2.1` using the reviewed release notes and correct tag.
- [ ] Record the release workflow URL and publication evidence; monitor issue/security reports.
- [ ] Track the deferred test-only POSIX locale MINOR as a follow-up after v0.2.1; do not alter v0.2.1 bytes after publication.

## Rollback

Do not overwrite or reuse version `0.2.1` after publication, move the published tag, or alter v0.1.0 or v0.2.0. Fix forward in a later patch version. If necessary, use the official [RubyGems yanking procedure](https://guides.rubygems.org/removing-a-published-gem/) and communicate the affected version; yanking does not remove installed copies.
