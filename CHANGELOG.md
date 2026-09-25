# Changelog

## 0.1.0 - Unreleased

- Extract positional `perform` contracts from native `Sidekiq::Job` and `Sidekiq::Worker` classes, including reopened classes.
- Discover direct Sidekiq enqueue calls and compare Git base and head snapshots in all three rolling deployment directions.
- Report JC001–JC007 in text or JSON schema version 1, with targeted `.jobcompat.yml` suppression.
- Check tracked Ruby declarations through a separate `DefinedConstantIndex` before reporting class removal.
- Provide a Prism based static CLI and RubyGem for Ruby 3.3 or newer without booting Rails or connecting to Redis.
