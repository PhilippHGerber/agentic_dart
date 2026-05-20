# Changelog

All notable changes to `pubdev_context` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `compare_packages` tool — compare 2–5 packages side by side as a `ComparisonMatrix`; fetches via the shared 15-minute package-metadata cache (compatible with `get_package` cache keys); requests are issued sequentially with a 100 ms inter-request gap; partial failures are reported per-package in `errors` without blocking successful columns
- `get_package` tool — fetch full `PackageDetail` for one package (metadata, scores, SDK constraints, dependencies, recent versions, README excerpt) with optional version pinning; 15-minute TTL cache
- `get_changelog` tool — fetch and parse a package changelog into a newest-first `List<ChangelogEntry>` with `breaking` flags; supports `from_version` exclusive lower bound and `version_limit` cap; 15-minute TTL cache
- `no_documentation` and `invalid_input` domain error codes

## [0.1.0] - 2026-05-11

### Added

- `search_packages` tool — search pub.dev by keyword with optional SDK, platform, and sort filters
- In-memory TTL response cache with per-entry expiry (5-minute TTL for search results)
- CLI configuration via `--log-level` and `--cache-dir` flags with env var fallback
- Stdio transport over stdin/stdout (via `dart_mcp ^0.5.1`)

## dart_mcp Compatibility

| pubdev_context | dart_mcp |
| ----------- | -------- |
| `0.1.x`     | `^0.5.1` |
