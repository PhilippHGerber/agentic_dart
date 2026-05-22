# Changelog

All notable changes to `pubdev_context` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Tool `search_api_symbols` renamed to `browse_api_symbols`. The new name reflects the tool's role as a pure discovery aid for when the symbol name is unknown;

## [0.3.0] - 2026-05-22

### Added

- `pub://meta/resources` — new static resource that returns a JSON array of every available resource and resource template, each with its URI, MIME type, and description. Read it first to discover what the server exposes without enumerating resources manually.
- Server instructions now list all six resource URIs and guide agents to read `pub://meta/resources` before making resource calls.

### Added (test)

- Integration test suite in `test/integration/` covering all five tools, four resources, and three lifecycle scenarios (49 tests total). Tagged `integration` in `dart_test.yaml`; excluded from the default `dart test` run via `paths: [test/unit]`. Run with `dart test test/integration/`.

### Changed

- All tool, resource, resource template, and prompt descriptions rewritten as direct agent instructions. Each description states when to call it, what to do with the result, which tool to call next, and which patterns to avoid. `search_api_symbols` now explicitly warns against multi-term queries.
- `PubDevClient` caps concurrent HTTP requests at 5 by default, preventing `429 Too Many Requests` errors when an agent issues several tool calls in parallel.

### Fixed

- `search_api_symbols` now reports correct symbol kinds. The `kind` integer from `index.json` was mapped to the wrong ordinal positions, causing enums to appear as `typedef`, mixins as `constant`, and some typedefs to fall through to a raw integer string.
- Package README and section extraction now uses DOM queries instead of regex. The previous approach returned content from the matched element to the end of the document and silently failed on elements with extra CSS classes, single-quoted attributes, or out-of-order class tokens.

## [0.2.0] - 2026-05-21

### Added

- `get_package` tool — full metadata for a named package: scores, SDK constraints, dependencies, recent versions, and README excerpt; supports optional version pinning
- `get_changelog` tool — parsed changelog as a newest-first list of entries with `breaking` flags; supports `from_version` lower bound and `version_limit` cap
- `compare_packages` tool — side-by-side `ComparisonMatrix` for 2–5 packages; partial failures are reported per package without blocking the remaining columns
- `get_symbol_documentation` tool — full dartdoc page for a specific API symbol as plain text
- `list_package_source_files` tool — file paths in a package tarball with optional `directory` and `fileExtension` filters; shares the 1-hour cache entry with `get_package_source_file`
- `get_package_source_file` tool — raw content of a single source file from the pub.dev package tarball; resolves version automatically when omitted; returns closest-filename suggestions on `source_file_not_found`
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


