# Changelog

## 0.2.0 - 2026-10-02

Broader native Sidekiq producer coverage:

- Recognize `perform_bulk`, Setter `perform_in` / `perform_at` / `perform_bulk`, and `Sidekiq::Client.push` / `push_bulk`.
- Normalize mixed bulk arities into distinct producer facts while retaining unknown rows.
- Emit JSON schema version 2 with producer uncertainty reasons for bulk and Client payloads.
- Resolve Client Hash splats and dynamic keys per key in source order, preserving known workers when only `"args"` is uncertain and preventing false JC005 when a later entry may replace `"class"`.
- Validate Client class Strings with Prism's Ruby constant syntax, preserving Unicode identities and reporting malformed or invalid-byte names as JC007.

## 0.1.0 - 2026-09-26

- Extract positional `perform` contracts from native `Sidekiq::Job` and `Sidekiq::Worker` classes, including reopened classes.
- Discover direct Sidekiq enqueue calls and compare Git base and head snapshots in all three rolling deployment directions.
- Report JC001–JC007 in text or JSON schema version 1, with targeted `.jobcompat.yml` suppression.
- Check tracked Ruby declarations through a separate `DefinedConstantIndex` before reporting class removal.
- Provide a Prism based static CLI and RubyGem for Ruby 3.3 or newer without booting Rails or connecting to Redis.
