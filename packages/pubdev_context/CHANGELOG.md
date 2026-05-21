# Changelog

All notable changes to `pubdev_context` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `get_package` tool — full metadata for a named package: scores, SDK constraints, dependencies, recent versions, and README excerpt; supports optional version pinning
- `get_changelog` tool — parsed changelog as a newest-first list of entries with `breaking` flags; supports `from_version` lower bound and `version_limit` cap
- `compare_packages` tool — side-by-side `ComparisonMatrix` for 2–5 packages; partial failures are reported per package without blocking the remaining columns
- `get_symbol_documentation` tool — full dartdoc page for a specific API symbol as plain text

- `add-and-setup-package` prompt — guides the LLM through reading a package README, explaining its purpose, writing boilerplate initialisation code, and listing native platform setup steps
- `analyze-upgrade-impact` prompt — guides the LLM through retrieving changelog entries, identifying breaking changes between two versions, and rewriting affected source code
- `evaluate-alternatives` prompt — guides the LLM through searching for packages matching a use case, comparing the top results, and producing a recommendation with a markdown comparison matrix

- `pub://meta/scoring` resource — plain-text explanation of pub.dev's 160-point scoring system; embedded at compile time
- `pub://meta/sdk-versions` resource — current stable Dart and Flutter SDK versions as a `{ dart, flutter }` JSON object
- `pub://package/{name}/readme` resource template — full package README as `text/markdown`
- `pub://package/{name}/example` resource template — package example code as `text/markdown`
- `pub://package/{name}/api` resource template — dartdoc symbol index as `application/json`
- `pub://package/{name}/changelog` resource template — full changelog as `text/markdown`

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
