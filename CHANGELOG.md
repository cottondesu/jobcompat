# Changelog

## 0.2.1 - 2026-10-04

Canonical worker-name consistency:

- Accept canonical Unicode worker names, such as names with combining marks and qualified `Admin::ÁJob`, in targeted `.jobcompat.yml` suppressions. Matching stays exact and is not Unicode-normalized.
- Share one Prism-based canonical worker-name validator between Client String producer analysis and Config.
- Report malformed, non-constant, or invalid-byte `ignore[].worker` names as normal config errors (exit 2). Names that are not Ruby constants, such as `管理::輸出`, were previously accepted but could never match a finding.

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
