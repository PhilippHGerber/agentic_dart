# Changelog

All notable changes to `dart_pubdev_mcp` are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.9.0]

### Changed

- **Breaking:** Standardized parameter names and response schemas across all tools (`package`, `symbol`, `kind`, `description`, `lineEnd`, `thrownType`, `pubPoints`) for consistent LLM tool-calling.

### Added

- `list_sdk_source_files`: added `directory` and `fileExtension` filters.
- `get_changelog`: added optional `version` parameter and structured `changes` list.

## [0.8.0]

### Added

- `get_sdk_release_notes` tool — retrieves structured release notes, categorized
  sections, and computed breaking change indicators for the Dart SDK and
  Flutter framework via raw upstream GitHub markdown, with a 24-hour in-memory
  cache and local SDK tarball fallback.

## [0.7.2]

### Changed

- `SDK_VERSION_NOT_FOUND` and `SDK_NOT_DETECTED` suggestions for the Flutter
  SDK tools (`get_sdk_source_slice`, `get_sdk_throw_statements`,
  `grep_sdk_source`, `list_sdk_source_files`) now guide an LLM caller through
  resolving a usable version — e.g. running `flutter --version --machine` and
  using its `frameworkRevision` (commit SHA) when `frameworkVersion` doesn't
  resolve to a tag, or asking the user when there's no shell access.

## [0.7.1]

### Fixed

- `directory` filters on `grep_sdk_source`, `grep_package_source`, and
  `list_package_source_files` now also match an exact full file path, not
  just a folder prefix — passing a complete file path (e.g. copied from a
  prior `matches[].file`) previously matched nothing silently instead of
  scoping the scan to that file.
- `browse_api_symbols`'s `kind` filter now matches case-insensitively (e.g.
  `"Class"` matches `"class"`) instead of silently returning `NO_RESULTS`.

## [0.7.0]

### Added

- `grep_sdk_source` tool — literal/regex search across the Dart or Flutter
  SDK's cached source tree, the SDK-source counterpart to
  `grep_package_source`. Defaults to scanning `.dart` files only (overridable
  via `fileExtension`), since an SDK/framework tarball is far noisier with
  non-Dart content than a pub.dev package.

### Changed

- `get_sdk_source_slice`'s `SYMBOL_NOT_FOUND` suggestion now mentions
  `grep_sdk_source` as a way to find a symbol by name/content.

## [0.6.5]

### Added

- `grep_package_source` tool — literal/regex search across a package's
  cached source tree, with optional context lines and directory/extension
  filters.
- `get_api_diff` gains an opt-in `includeSignatureChanges` parameter (with a
  required `symbol`) that adds a `signatureChange` field comparing one
  declaration's signature across versions.

## [0.6.4]

### Added

- `get_security_advisories(package, version?)` tool — evaluates a package's
  security advisories (pub.dev's OSV-format advisories endpoint) against the
  Resolved Version, separating advisories that affect the Resolved Version
  from those that don't. Each entry carries id, aliases (CVEs), summary,
  affected ranges, and a URL. Responses are cached with a TTL.

### Changed

- `get_package` gains a best-effort `advisories` summary (count, ids, whether
  the Resolved Version is affected); a failed advisories fetch never fails
  the parent call.
- `compare_packages`'s Comparison Matrix gains a best-effort `advisories` row
  with per-package advisory counts, on the same best-effort terms.
- Clarified tool descriptions to surface existing capabilities that were
  previously easy to miss: `list_package_source_files` and `get_source_slice`
  now state that the whole package archive is browsable (`example/`, `test/`,
  `bin/` — not just `lib/`), and `search_packages` documents pub.dev search
  qualifiers (`publisher:`, `dependency:`, `topic:`, `license:`, `has:`,
  `sdk:`) with the Non-Relevance Sort caveat.

## [0.6.3]

### Changed

- The Update Notice (`dartPubdevMcpUpdate`) now includes a `message` field
  that directly instructs the model to relay the pending update to the
  user, alongside the existing `current`/`latest` fields — landing in the
  model's context didn't guarantee the model would mention it unprompted.

## [0.6.2]

### Added

- SDK source reading, per [ADR 0006](docs/adr/0006-sdk-source-reading.md): three
  new tools spanning both the Dart SDK and the Flutter SDK/framework via an
  `sdk: 'dart' | 'flutter'` selector, backed by download-only GitHub tarballs.
  - `get_sdk_source_slice` — line-range mode and symbol-bounded mode (AST-located
    class/mixin/enum/function/typedef/variable, or member via `ClassName.member`).
  - `list_sdk_source_files` — directory/extension-filtered file listing.
  - `get_sdk_throw_statements` — scans throw expressions in a class or top-level
    function, with surrounding control-flow context.

## [0.6.1]

### Added

- `--version` now prints an `Update available:` line when a newer version
  is known, and MCP clients receive a one-time `notifications/message`
  log push when a newer version is found (sent regardless of `--log-level`).

## [0.6.0]

### Changed

- **Breaking:** unified parameter naming across the tool surface — package
  name is now always `package`/`packages`, multi-word parameters use
  camelCase, result caps are `limit`, and the symbol-kind filter is
  `kind`. No aliases: old names now fail with `INVALID_ARGUMENT`.
  - `get_package`, `get_changelog`, `list_package_versions`,
    `list_package_source_files`: `name` → `package`
  - `compare_packages`: `names` → `packages`
  - `get_changelog`: `from_version` → `fromVersion`; `version_limit` → `limit`
  - `browse_api_symbols`: `type` → `kind`

### Added

- Tool responses now include `structuredContent` matching each tool's new
  `outputSchema` (all tools except `search_packages`), for clients that
  want to validate results against a typed contract.

## [0.5.2]

### Added

- Self-update notice: the server checks pub.dev once per startup (rate-limited to ~24h across restarts) and, if a newer version exists, surfaces a `dartPubdevMcpUpdate` notice on the next tool-call response — at most once per session.
- `--no-update-check` flag / `dart_pubdev_mcp_UPDATE_CHECK` env var to disable it (default: on).

## [0.5.1]

### Fixed

- README.md

## [0.5.0]

### Changed

- **Breaking:** package renamed from `pubdev_context` to `dart_pubdev_mcp`. Version reset to `0.5.0` — not a continuation of the `0.4.0-rc.x` PoC line's numbering. Deliberately kept below `1.0.0`: the V1 tool surface is still considered pre-stable under semver, so the version number doesn't yet claim API stability.
