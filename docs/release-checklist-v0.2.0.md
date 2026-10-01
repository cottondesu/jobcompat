# jobcompat v0.2.0 release checklist

This is preparation for an update to the already published `jobcompat` gem. Checked boxes record completed preparation checks; unchecked boxes are final release or post-publication gates, not claims of completion. No v0.2.0 tag or publication is authorized by this document.

## Release identity

- Repository: `cottondesu/jobcompat`, branch `main`.
- Gem version: `0.2.0`; intended annotated tag: `v0.2.0`.
- Intended release date: `2026-10-02`. If execution is delayed, reconcile the CHANGELOG date with the actual intended date before tagging; never backdate publication.
- JSON schema: `2`; `.jobcompat.yml` configuration schema: `1`.
- Implementation commit: `c107c9a9868cf3d29f4b821444fe1e0cfcb86820`.
- Release candidate commit: to be determined after the `Prepare v0.2.0 release` commit. Record its exact SHA and CI run in the final release execution record; do not select a moving `main` ref without verification.

## Automated validation

- [x] Implementation commit passed [CI run 36875203650](https://github.com/cottondesu/jobcompat/actions/runs/36875203650): Ruby 3.3, 3.4, and 4.0 PASS; each ran 122 tests / 902 assertions and built the Gem.
- [x] Candidate local `bundle exec rake test` on Ruby 3.4.11 / Prism 1.9.0: 122 tests, 902 assertions, zero failures, errors, and skips.
- [x] Candidate `git diff --check` and release-only diff review pass; product bytes match the implementation commit.
- [x] Build the candidate Gem and inspect its 24 entries, including both v0.2.0 release documents. No local tooling state, credentials, caches, scratch files, or nested Gems are included.
- [x] Install the candidate Gem into a fresh isolated destination; version/help, clean 0, compatibility error 1, warning-only 0, invalid ref 2, and config version 1 pass.
- [ ] Record the pushed release-preparation SHA and its CI run; require Ruby 3.3, 3.4, and 4.0 success on that exact SHA before tagging. The implementation run above does not substitute for candidate CI.

## Publication prerequisites

- [x] On 2026-10-02, public RubyGems listed `0.1.0` and no `0.2.0`; public owner handle was `cottondesu`, and metadata pointed to this repository.
- [x] On 2026-10-02, local/remote tags and GitHub Releases contained `v0.1.0` and no `v0.2.0`.
- [x] GitHub environment `release` exists, requires reviewer `cottondesu`, and permits tag pattern `v*`.
- [ ] Confirm the current RubyGems Trusted Publisher for `jobcompat` in the maintainer UI: owner `cottondesu`, repository `jobcompat`, workflow file `release.yml`, environment `release`. Public package metadata and earlier publication are not proof of the current publisher settings. See [Trusted Publishing](https://guides.rubygems.org/trusted-publishing/).
- [x] Release workflow retains tag/version and public metadata gates. Gem homepage, source, changelog, and issue URLs refer to `cottondesu/jobcompat`.
- [x] Review the v0.2.0 release notes against the normative scope and inspect the built candidate package.
- [ ] Immediately before release execution, recheck that `0.2.0` is absent on RubyGems and `v0.2.0` is absent locally, remotely, and in GitHub Releases. Stop if any already exists; never overwrite it.

## Tag gate

**Pushing `v0.2.0` triggers the Release workflow and may publish the Gem automatically. Treat tag push as a publication action.**

- [ ] Complete every pre-tag validation and publication prerequisite above, including the manual Trusted Publisher check and exact candidate CI.
- [ ] Obtain separate final release execution approval. Release preparation alone does not authorize tagging or publication.
- [ ] Confirm the exact release candidate SHA, product version, intended release date, and unchanged v0.1.0 release identity.
- [ ] Under that separate approval, create an annotated `v0.2.0` tag on the verified SHA and push only that tag. Do not force or push unrelated tags.

## Release workflow verification

The unchanged `.github/workflows/release.yml` triggers on pushes matching `v*`. Its Ruby 3.3 / 3.4 / 4.0 tests precede the `publish` job through `needs: test`. Publication uses Ruby 4.0, environment `release`, GitHub OIDC `id-token: write`, pinned `rubygems/configure-rubygems-credentials`, and `gem push`.

- [ ] Verify the triggered Release run refers to the approved tag and exact candidate SHA.
- [ ] Confirm all three test jobs pass and the publication environment approval is satisfied.
- [ ] Confirm `GITHUB_REF_NAME == "v#{Jobcompat::VERSION}"`, public metadata checks, publication-job tests, build, credentials setup, and push all succeed.
- [ ] Confirm RubyGems lists `jobcompat` version `0.2.0`; do not infer publication solely from a tag or a partial workflow result.

## After publication

- [ ] Check RubyGems version, ownership, Ruby/dependency requirements, public URLs, and package contents.
- [ ] Install `jobcompat` 0.2.0 from RubyGems in a clean environment; verify version/help and representative CLI checks.
- [ ] Under the separate release approval, create or verify the GitHub Release for `v0.2.0` using the reviewed release notes and correct tag.
- [ ] Record the release workflow URL and publication evidence; monitor issue/security reports.
- [ ] Track the pre-existing Unicode suppression validator limitation as a possible v0.2.1 follow-up; do not alter v0.2.0 bytes after publication.

## Rollback

Do not overwrite or reuse version `0.2.0` after publication, move the published tag, or alter v0.1.0. Fix forward in `0.2.1`. If necessary, use the official [RubyGems yanking procedure](https://guides.rubygems.org/removing-a-published-gem/) and communicate the affected version; yanking does not remove installed copies.
