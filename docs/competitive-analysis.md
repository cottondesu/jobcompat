# jobcompat competitive analysis

- Research date: 2026-09-23 (Asia/Tokyo)
- Product hypothesis: **Breaking-change detector for queued background jobs**
- Initial scope: Ruby source, native Sidekiq jobs, Git revision comparison
- Repository state at research start: the project directory was not a Git repository and contained no product files; only local tooling state existed.

## Executive conclusion

No mature direct competitor was found that statically derives native Sidekiq producer and consumer contracts from two Git revisions and checks both rolling-deployment directions. This is a bounded research conclusion, not proof that no such project exists.

The problem itself is real and documented by primary sources. Sidekiq stores the job class and an `args` array, then splats that array into `perform`; GitLab explicitly documents all three mixed-version situations that jobcompat proposes to check. The gap is therefore not problem discovery, but automated, revision-aware enforcement for ordinary native Sidekiq code.

Recommendation: **go**, with a deliberately narrow v0.1. The differentiator should be phrased as:

> A Git-aware static compatibility check for native Sidekiq job arity across rolling deployments.

Do not claim to prove runtime safety, queue emptiness, payload types, Hash schemas, feature-flag behavior, or arbitrary Ruby metaprogramming.

## Methodology

### Sources and evidence policy

Research prioritized, in order:

1. upstream framework repositories and official documentation;
2. GitHub repositories and their public metadata API;
3. package registries (RubyGems, npm, PyPI);
4. GitLab-hosted OSS results;
5. general web search for discovery only.

Material claims below link to primary or upstream sources. GitHub stars and `pushed_at` values were read from the public GitHub repository API on 2026-09-23. Stars are a volatile popularity signal, not a quality score. A package endpoint returning HTTP 404 is evidence only that the exact package was not found at that time; it is not a reservation or trademark clearance.

### Query families searched

The following requested terms were searched individually or in grouped exact/OR queries against GitHub and general web search:

```text
sidekiq compatibility checker
sidekiq breaking change checker
background job compatibility checker
background job contract checker
job payload compatibility
queue payload compatibility
queued job compatibility
worker signature compatibility
sidekiq worker compatibility
sidekiq argument compatibility
sidekiq deployment compatibility
async contract checker
job contract linter

sidekiq typed arguments
typed sidekiq jobs
sidekiq sorbet
sidekiq argument validation
sidekiq schema
sidekiq linter
rubocop sidekiq
rspec sidekiq
sidekiq static analysis
BullMQ schema
BullMQ Zod
Celery argument validation
Celery task signature
queue schema registry
```

Additional searches covered Prism AST node documentation, Sidekiq Job Format and scheduling APIs, GitLab Sidekiq update compatibility, AsyncAPI diffing, Kafka-compatible schema registries, Ruby maintenance status, and the proposed positioning phrase.

GitLab-specific searches for Sidekiq compatibility checkers, background-job contracts, queue-payload compatibility, and Sidekiq argument linters returned GitLab's own documentation and issues, but no standalone direct checker.

RubyGems-, npm-, and PyPI-oriented keyword searches were also run for the relevant ecosystems (Sidekiq/Ruby, BullMQ/Node, and Celery/Python). They surfaced the adjacent projects summarized below, but no package whose documented feature set combined native Sidekiq source extraction, Git revision comparison, and both mixed-version deployment directions. Registry search is not exhaustive, so this remains a bounded result.

### Registry and name checks

Exact public endpoints checked on 2026-09-23:

| Registry | Exact endpoint | Result |
| --- | --- | --- |
| RubyGems | `https://rubygems.org/api/v1/gems/jobcompat.json` | HTTP 404 |
| npm | `https://registry.npmjs.org/jobcompat` | HTTP 404 |
| PyPI | `https://pypi.org/pypi/jobcompat/json` | HTTP 404 |
| GitHub repository search | `jobcompat in:name` | 3 fuzzy-name results; no exact `jobcompat` repository name in the returned set |

The GitHub fuzzy results were unrelated job-matching projects: `RubyWoodsDev/JobCompatablity`, `Candace352/JobCompatibility`, and `Candace352/JobCompatibilityChecker`.

## Primary-source validation of the problem

### Sidekiq's persisted contract

Sidekiq's [Job Format](https://github.com/sidekiq/sidekiq/wiki/Job-Format) documents a payload containing a class name and an `args` array, and states that `args` is splatted into the job class's `perform` method. Its [Best Practices](https://github.com/sidekiq/sidekiq/wiki/Best-Practices) explains that `perform_async` arguments are JSON-persisted in Redis. The [Basics](https://github.com/sidekiq/sidekiq/wiki/The-Basics) distinguishes the client that enqueues the serialized job from the server that later instantiates the class and calls `perform`.

This establishes the core contract used by jobcompat v0.1:

```text
serialized class name + positional args array
                   -> worker instance #perform(*args)
```

Sidekiq's [Scheduled Jobs](https://github.com/sidekiq/sidekiq/wiki/Scheduled-Jobs) confirms that `perform_in(interval, *args)` and `perform_at(timestamp, *args)` reserve the first argument for scheduling. [Advanced Options](https://github.com/sidekiq/sidekiq/wiki/Advanced-Options) confirms `Job.set(queue: ...).perform_async(...)`.

Sidekiq's strict argument checking, introduced in 6.4 and made strict in 7, checks whether argument values are JSON-safe. It does not compare worker arity or Git revisions; see the upstream [Changes](https://github.com/sidekiq/sidekiq/blob/main/Changes.md).

### GitLab's rolling-deployment model

GitLab's [Sidekiq Compatibility across Updates](https://docs.gitlab.com/development/sidekiq/compatibility_across_updates/) names the same three situations:

1. an old application version publishes a job executed by an upgraded Sidekiq node;
2. a job queued before an upgrade executes after the upgrade;
3. a new application node publishes a job executed by an old Sidekiq node.

It recommends a multi-release sequence: first add an optional worker argument, later start producing it, and only later make it required. It also treats adding, removing, and renaming worker classes as rollout concerns. This is strong evidence for the proposed A/B/C compatibility model and for JC002/JC004/JC005.

GitLab is guidance, not a reusable checker. Its value to jobcompat is validation of deployment semantics and remediation wording.

## Competitor and adjacent-tool matrix

Legend: “revision comparison” means comparison of two versions of the relevant contract, not merely version-control integration. “Old → new” and “new → old” refer to producer/consumer compatibility.

| Name | URL | Category | Framework | Core feature | Static analysis | Revision comparison | Old producer → new consumer | New producer → old consumer | Rolling aware | CI-oriented | Activity at 2026-09-23 | Stars | License | Difference from jobcompat |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | --- | --- |
| GitLab Sidekiq compatibility guidance | [docs](https://docs.gitlab.com/development/sidekiq/compatibility_across_updates/) | adjacent | Sidekiq | Operational rules and staged migrations across updates | no | no | described manually | described manually | yes | no standalone gate | current docs accessible | n/a | GitLab documentation terms | Strongest validation of the problem, but provides no reusable AST/Git checker |
| Sidekiq strict arguments | [upstream](https://github.com/sidekiq/sidekiq), [changes](https://github.com/sidekiq/sidekiq/blob/main/Changes.md) | adjacent | Sidekiq | Reject JSON-unsafe enqueue arguments | no; runtime enqueue validation | no | no | no | no | usable in tests/runtime, not a revision gate | pushed 2026-09-23 | 13,561 | LGPL-3.0 | Validates serialization safety, not class/arity evolution |
| Sidekiq::Sorbet | [GitHub](https://github.com/akodkod/sidekiq-sorbet) | adjacent | Sidekiq + Sorbet DSL | Typed `T::Struct` arguments, enqueue-time validation, custom `run_*` API | type generation plus runtime validation | no | no | no | no | potentially | pushed 2026-04-27 | 1 | MIT | Requires a different DSL and does not compare deployed revisions or native `perform_async` callsites |
| RuboCop | [GitHub](https://github.com/rubocop/rubocop) | adjacent | Ruby | General single-tree static analysis and linting | yes | no | no | no | no | yes | pushed 2026-09-22 | 12,904 | MIT | Extensible analysis platform, but no discovered Sidekiq rolling-contract rule; jobcompat is cross-revision and domain-specific |
| AsyncAPI Diff | [GitHub](https://github.com/asyncapi/diff), [CLI](https://github.com/asyncapi/cli/blob/master/docs/usage.md) | adjacent | AsyncAPI | Diff declared async API documents and classify breaking changes | yes, on specifications | yes, document-to-document | schema-dependent | schema-dependent | not deployment-topology aware | yes | pushed 2026-08-06 | 28 | Apache-2.0 | Requires an explicit AsyncAPI document; does not infer native Sidekiq contracts or mixed-version fleet directions |
| BullMQ-Zod | [GitHub](https://github.com/AprilNEA/bullmq-zod) | adjacent | BullMQ | Zod-backed compile-time/runtime payload validation | no revision static analysis | no | no | no | no | potentially | pushed 2025-01-21 | 2 | MIT | Schema wrapper for another framework, not a Git diff or rolling-deploy checker |
| Celery argument checking | [official tasks docs](https://docs.celeryq.dev/en/latest/userguide/tasks.html), [GitHub](https://github.com/celery/celery) | adjacent | Celery | Call-time task signature argument checking; optional typing/validation | runtime/call-time | no | no | no | no | potentially | pushed 2026-09-23 | 28,913 | BSD-3-Clause | Confirms adjacent demand, but does not compare revisions or Sidekiq source |
| Karapace Schema Registry | [GitHub](https://github.com/Aiven-Open/karapace) | adjacent | Kafka/schema registry | Store schemas and enforce configured schema compatibility | schema analysis | yes, schema versions | yes for configured schema mode | yes for configured schema mode | protocol compatibility, not app rollout topology | yes | pushed 2026-09-21 | 636 | Apache-2.0 | Mature schema-registry pattern, but requires declared schemas and targets event streams rather than native Sidekiq method calls |

### Excluded from the matrix

The following were reviewed but excluded because they do not materially address contract compatibility:

- Sidekiq queue UIs, retry tooling, schedulers, uniqueness gems, and job-iteration libraries;
- generic background-job processors;
- gems that only serialize or encrypt arguments;
- RSpec Sidekiq helpers that assert enqueue behavior in one revision;
- unrelated repositories whose names happen to include “job compatibility.”

This avoids manufacturing a large competitor set from unrelated projects.

## Direct competitor assessment

### Direct competitor found?

**No direct competitor was found in the searched sources.** Specifically, no discovered project combined all of:

- native Sidekiq worker and producer discovery from ordinary Ruby source;
- base/head Git snapshot comparison;
- old producer → new consumer analysis;
- new producer → old consumer analysis;
- current head producer → head consumer analysis;
- CI-oriented deterministic findings.

This statement is limited by public indexing, query quality, private/internal tools, abandoned unindexed projects, and future releases.

### Mature OSS solving substantially the same problem?

**None found.** The mature adjacent solutions solve different layers:

- Sidekiq checks JSON serialization at enqueue time;
- GitLab documents safe deployment practice;
- typed wrappers change the programming model and validate one version;
- AsyncAPI/schema registries compare explicit schemas rather than infer application contracts;
- general linters analyze one source tree.

### Strongest adjacent competitors

1. **GitLab's compatibility guidance** is the strongest conceptual substitute. Teams can enforce it through review discipline without installing a tool.
2. **Sidekiq::Sorbet and other typed wrappers** can prevent some producer mistakes, but adoption requires code changes and still does not model old/new fleets.
3. **AsyncAPI Diff/schema registries** demonstrate a mature schema-compatibility category. They become stronger substitutes if a team already declares job payload schemas outside Ruby code.

## Differentiation

The defensible v0.1 differentiation is the intersection of four choices:

1. **Revision-aware:** compare immutable Git snapshots, not only the current tree.
2. **Deployment-aware:** model both directions of a mixed-version rolling deploy.
3. **Source-derived:** work with existing native Sidekiq classes and enqueue calls, without requiring schema adoption or application boot.
4. **Conservative evidence:** errors require a concrete structural incompatibility; unsupported/dynamic evidence remains a warning or tool error, never a pass.

The most distinctive rule is JC002: a new producer arity accepted by the head worker but rejected by the base worker. Single-tree linters and ordinary tests commonly miss this rollout window.

## Market and product risks

| Risk | Consequence | v0.1 response |
| --- | --- | --- |
| Ruby metaprogramming hides workers/calls | False negatives or false removal errors | Narrow supported syntax; a tracked class still present but unrecognized blocks JC004 and yields JC007 |
| Repository callsites do not prove queued data | False confidence or noisy errors | JC001 requires a known base callsite; JC006 warns on unproven contract narrowing and explicitly avoids inferring an empty queue |
| Feature flags make an unsafe-looking call operationally safe | JC005/JC002 false positive | Exact rule+worker suppression with mandatory reason |
| Tests/examples look like production producers | False errors | Default-exclude `test/**`, `spec/**`, `features/**`, and `examples/**` |
| Dynamic receivers are common | JC007 noise | Warning only; never infer a worker; path exclusion is available |
| Native Sidekiq users may use `Sidekiq::Client.push` or bulk APIs | False negatives | Explicit v0.1 non-goal and roadmap item |
| Full-repository parsing may be slow | Poor CI adoption | Parse selected blobs once; use a bounded, lazy presence-only pass over excluded tracked Ruby only for potential class-absence errors, returning JC007 if proof cannot finish |
| “Compatibility” could be mistaken for value/type compatibility | Overclaiming | Name v0.1 capability “positional arity compatibility” in README and output |
| Package name may be claimed before release | Rename cost | Reserve GitHub/RubyGems shortly before implementation/release; do not state availability as guaranteed |

## Package and project name due diligence

`jobcompat` is concise, easy to type, and communicates compatibility better than a Sidekiq-specific name. It leaves room for future adapters without promising them in v0.1.

At the research date, exact RubyGems, npm, and PyPI API lookups returned 404, and GitHub's name search returned no exact repository named `jobcompat`. This supports continuing with the name, but does **not** establish legal clearance, future availability, organization-name availability, domain availability, or trademark safety.

The proposed phrase:

> Your API has a schema. Your database has migrations. What protects your queued jobs?

returned no exact matching product phrase in the sampled web searches. This is not a trademark search. Use it as draft positioning and perform a final general/trademark review before a public launch campaign.

Contingency names, not separately cleared:

- `queuecompat`
- `jobcontract`
- `queuediff`
- `asynccompat`
- `jobguard`

## Final differentiation assessment

- **Direct competitor:** none found in the bounded search.
- **Mature equivalent OSS:** none found.
- **Market gap:** credible and specifically supported by Sidekiq payload semantics and GitLab deployment guidance.
- **Differentiation:** clear if jobcompat remains the Git-aware, mixed-version, native-Sidekiq arity checker.
- **Go / reconsider:** **go for v0.1**. Reconsider only if implementation discovery shows that ordinary producer receivers cannot be resolved with acceptable precision, or if a newly found tool already performs the same three-direction Git analysis.

## Source index

### Required primary sources

- [Sidekiq repository](https://github.com/sidekiq/sidekiq)
- [Sidekiq Job Format](https://github.com/sidekiq/sidekiq/wiki/Job-Format)
- [Sidekiq Best Practices](https://github.com/sidekiq/sidekiq/wiki/Best-Practices)
- [Sidekiq Basics](https://github.com/sidekiq/sidekiq/wiki/The-Basics)
- [Sidekiq Scheduled Jobs](https://github.com/sidekiq/sidekiq/wiki/Scheduled-Jobs)
- [Sidekiq Advanced Options](https://github.com/sidekiq/sidekiq/wiki/Advanced-Options)
- [Sidekiq changes, including strict args](https://github.com/sidekiq/sidekiq/blob/main/Changes.md)
- [Sidekiq related projects](https://github.com/sidekiq/sidekiq/wiki/Related-Projects)
- [GitLab Sidekiq Compatibility across Updates](https://docs.gitlab.com/development/sidekiq/compatibility_across_updates/)
- [Prism official documentation](https://ruby.github.io/prism/)
- [Prism Ruby API](https://ruby.github.io/prism/rb/docs/ruby_api_md.html)
- [Prism node schema](https://github.com/ruby/prism/blob/main/config.yml)

### Version and dependency sources

- [Ruby maintenance branches](https://www.ruby-lang.org/en/downloads/branches/)
- [Sidekiq gemspec](https://github.com/sidekiq/sidekiq/blob/main/sidekiq.gemspec)
- [Prism on RubyGems](https://rubygems.org/gems/prism)
- [`parser` README recommending native Prism for Ruby 3.3+](https://github.com/whitequark/parser/blob/master/README.md)
- [`parser` on RubyGems](https://rubygems.org/gems/parser/)

### Adjacent projects

- [Sidekiq::Sorbet](https://github.com/akodkod/sidekiq-sorbet)
- [RuboCop](https://github.com/rubocop/rubocop)
- [AsyncAPI Diff](https://github.com/asyncapi/diff)
- [AsyncAPI CLI diff command](https://github.com/asyncapi/cli/blob/master/docs/usage.md)
- [BullMQ Job Data](https://docs.bullmq.io/guide/jobs/job-data)
- [BullMQ-Zod](https://github.com/AprilNEA/bullmq-zod)
- [Celery Tasks](https://docs.celeryq.dev/en/latest/userguide/tasks.html)
- [Karapace](https://github.com/Aiven-Open/karapace)

### Git snapshot design sources

- [`git rev-parse`](https://git-scm.com/docs/git-rev-parse)
- [`git ls-tree`](https://git-scm.com/docs/git-ls-tree)
- [`git cat-file`](https://git-scm.com/docs/git-cat-file)
