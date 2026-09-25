# jobcompat v0.1.0 release notes (draft)

jobcompat v0.1.0 is the first public release. It detects native Sidekiq positional argument compatibility issues across Git revisions before deployment.

## Highlights

- Reads committed Ruby source with Prism; no schema, annotation, Redis connection, or Rails boot is needed.
- Checks base producer to head consumer, head producer to base consumer, and head producer to head consumer for rolling deployments.
- Reports JC001–JC007 in text and JSON schema version 1; supports focused suppression with a reason.
- Tracks reopened worker classes and checks tracked declarations before reporting a class as removed.

For example, changing `def perform(user_id)` to `def perform(user_id, notify)` can produce `ERROR JC001` when the base revision enqueues a one argument job. That queued job may fail after the new worker deploys.

## Supported scope

Ruby 3.3 or newer, native `Sidekiq::Job` and `Sidekiq::Worker`, direct enqueue calls, and positional arity between two Git commits.

## Known limitations

ActiveJob, keyword compatibility, payload types and Hash schemas, live Redis queues, wrappers and aliases, feature flags, runtime metaprogramming, and general Ruby constant conflicts are outside v0.1 scope. An undiscovered producer does not prove the queue empty.

## Installation

After publication, run `gem install jobcompat` and then `jobcompat check --base origin/main`. Bundler users can add `gem "jobcompat", require: false` and run `bundle exec jobcompat check --base origin/main`.
