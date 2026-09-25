# jobcompat v0.1.0 release checklist

This checklist is for the future gem release. The public repository is `https://github.com/cottondesu/jobcompat`; initial publication of `main` is authorized, but tagging, publishing a gem, and creating a GitHub Release are reserved for the release phase. Gem version `0.1.0` uses tag `v0.1.0`; JSON `schema_version: 1` is a separate contract.

## Local, machine executable checks

- [x] Recheck exact `jobcompat` availability on RubyGems and search GitHub before the initial public push. A missing registry response does not reserve the name.
- [x] Run `bundle exec rake test` on Ruby 3.4 and 4.0: 79 tests, 367 assertions, 0 failures, 0 errors on each.
- [x] Check Ruby syntax in `lib/`, `exe/`, `test/`, and the gemspec.
- [x] Build the gem with Ruby 3.4 and 4.0; no gem build warnings.
- [x] Inspect the built gem: executable, `lib/`, README, LICENSE, CHANGELOG, SECURITY, and docs present; no caches, credentials, temporary repositories, `.git`, or built gems.
- [x] Install the built gem into an isolated gem home and run `jobcompat --help`, `jobcompat --version`, and checks that exit 0 for clean, 1 for JC001, 0 for warning only, and 2 for a bad Git ref. Parse JSON output.
- [x] Repeat the secret and personal path scan; review README, CHANGELOG, LICENSE, release notes, and workflow against the built gem.
- [x] Verify every GitHub Action reference is a pinned commit SHA and inspect the diff before the initial commit.

## Manual gates before publication

- [x] Create the public [`cottondesu/jobcompat`](https://github.com/cottondesu/jobcompat) repository with default branch `main`.
- [x] Set the real repository URL in gemspec `homepage`, `source_code_uri`, `changelog_uri`, and `bug_tracker_uri`.
- [x] Enable Issues, private vulnerability reporting, Dependabot alerts and security updates, secret scanning, and push protection on [`cottondesu/jobcompat`](https://github.com/cottondesu/jobcompat).
- [ ] Configure a `main` ruleset or branch protection that blocks force pushes and deletion and requires successful CI; avoid unnecessary review gates for a single maintainer.
- [ ] Confirm GitHub two factor authentication and RubyGems MFA.
- [ ] Protect the GitHub `release` environment with appropriate approval or deployment restrictions.
- [ ] Confirm Ruby 3.3, 3.4, and 4.0 GitHub CI jobs all pass on the exact release candidate. Ruby 3.3 CI is mandatory because the local runtime has not been tested.
- [ ] Configure a RubyGems [Pending Trusted Publisher](https://guides.rubygems.org/trusted-publishing/) for the new `jobcompat` gem using GitHub owner `cottondesu`, repository `jobcompat`, workflow file `release.yml`, and environment `release`. Confirm the details match the release workflow. Do not store a long lived RubyGems API key in GitHub Secrets.
- [ ] Recheck that `jobcompat` is still unregistered on RubyGems immediately before the actual gem publication.
- [ ] Review the tag triggered release workflow and built gem one final time before pushing `v0.1.0`.

## Exact publication sequence (future manual actions)

1. Recheck gem name before every public push and again immediately before gem publication.
2. Rerun local tests, build, install, smoke checks, package review, and secret scan. Resolve every build warning.
3. Make the initial commit and push `main` to [`cottondesu/jobcompat`](https://github.com/cottondesu/jobcompat).
4. Confirm Ruby 3.3, 3.4, and 4.0 CI green and configure repository settings, ruleset, private reporting, and account MFA.
5. Configure and protect GitHub environment `release` and create the RubyGems Pending Trusted Publisher with its exact owner/repository/workflow/environment identity.
6. Review the final source, tag/version match, gem contents, and release notes. Create tag `v0.1.0` and push it only after all gates pass.
7. Observe the release workflow tests, build, and OIDC publish job. Confirm `jobcompat` version `0.1.0` appears on RubyGems.
8. Install from RubyGems in a clean environment. Run `jobcompat --version` and `jobcompat --help`.
9. Create or verify the GitHub Release using the draft release notes and confirm tag and download links.

## After publication

- [ ] Check the RubyGems name, version, metadata, homepage, source URL, and changelog URL.
- [ ] Confirm GitHub tag, Release, README installation instructions, and installed CLI behavior.
- [ ] Confirm RubyGems lists the trusted publisher and monitor initial issue/security reports.

## Rollback

Do not overwrite a published gem or reuse version `0.1.0`. Fix a serious issue in `0.1.1` and follow the same gates. If yanking is necessary, use the official [RubyGems yanking procedure](https://guides.rubygems.org/removing-a-published-gem/) and communicate the affected version; yanking does not erase copies already installed.
