# dart_pubdev_mcp

An MCP server that gives LLM agents structured, version-aware, token-efficient access to Dart and Flutter packages on pub.dev.

## Language

### Naming

**Package Identifier**: The `pubspec.yaml` `name:` / pub.dev listing name — `dart_pubdev_mcp` (`lowercase_with_underscores`; pub.dev rejects hyphens). Distinct from MCP Server Identity.

**MCP Server Identity**: The name presented to MCP clients — handshake `Implementation.name`, `.mcp.json` key, CLI executable — `dart-pubdev-explorer`. Hyphens allowed.

### Distribution units

**Package**: A pub.dev distribution unit (name + version) containing one or more libraries.
_Avoid_: module, gem, dependency

**Library**: A named Dart grouping (`library` directive or file-level) forming a package's public API.
_Avoid_: module, namespace

**Symbol**: A named, documentable Dart declaration indexed in dartdoc's `index.json` (classes, methods, functions, constructors, enums, mixins, extensions, typedefs, accessors, top-level constants/properties). Excludes libraries and packages.
_Avoid_: API element, declaration

### Versioning

**Latest Stable Version**: Newest published version with no pre-release suffix (`-alpha`/`-beta`/`-rc`/`-dev`). Default fallback when `version` is omitted.
_Avoid_: latest version (ambiguous re pre-releases)

**Resolved Version**: The exact semver string a tool call actually used, returned as top-level `resolvedVersion`. Absent on `search_packages` and `compare_packages` (per-package `version` instead).

**Update Check**: Rate-limited (~24h) background lookup of this server's own Latest Stable Version, once per startup. Disableable via `--no-update-check` / `dart_pubdev_mcp_UPDATE_CHECK`. Failures are silent.

**Update Notice**: The `dartPubdevMcpUpdate` object piggybacked on the first eligible tool response of a session when a newer version exists. At most once per process; text-content only, never `structuredContent`.

**Update Banner**: Two-line addition to `dart-pubdev-explorer --version` output when an update is available. Read-only, no network call.

**Update Log Notification**: One-time MCP `notifications/message` push carrying the Update Banner's text, sent outside the severity-gated `log()` path.

**Package Resource URI**: Canonical versioned resource address, e.g. `pub://package/http@1.2.0/readme`. Always includes `@{version}` (`latest` is legal). See ADR 0001.

**Version Listing**: `list_package_versions` output — `stable`/`prerelease`/`retracted` lists, newest-first, each with version + `publishedAt`.

### Symbols and source

**Symbol Identity**: Fully-qualified name + library URI + package version, e.g. `CueTimelineController`, `package:cue/cue.dart`, `1.2.0`. Returned by `find_symbols`; consumed by `get_symbol_documentation`/`get_source_slice`.

**Symbol Search**: Case-insensitive substring/fuzzy match against symbol names and descriptions in one package's dartdoc index. Up to 20 results + `hasMore`.

**Symbol Search Result**: One `find_symbols` entry — `{ name, qualifiedName, kind, library, enclosedBy, description, href }`.

**Source Slice**: A `get_source_slice` extract — line-range mode (`lineStart`/`lineEnd`, exact) or symbol-bounded mode (AST-located, optional `maxLines` truncation with `truncated`/`effectiveLineEnd`).

**Grep Match**: One `grep_package_source` match — `{ file, line, matchedLine, contextBefore, contextAfter }`. Literal substring by default, `RegExp` when `regex: true`; case-sensitive unless `caseInsensitive: true`.

**API Diff**: `get_api_diff` output — added/removed libraries, classes, fields, methods between two versions (presence-based, not structural). `DOCUMENTATION_NOT_FOUND` if dartdoc is missing for either version. Opt-in `includeSignatureChanges` + `symbol` adds a Signature Change for one declaration.

**Signature Change**: `get_api_diff`'s opt-in `signatureChange` result — `{qualifiedName, changed, before, after}` — an AST-reconstructed, formatting-invariant header comparison for one `symbol` across both versions. `symbol` must resolve in both or the call fails with `SYMBOL_NOT_FOUND`.

**Security Advisory**: One OSV-format entry from pub.dev's advisories endpoint — id, CVE aliases, summary, URL, affected ranges. Not version-scoped; `get_security_advisories` does the per-version evaluation.

**Advisories Summary**: Best-effort `advisories` field (`count`, `ids`, `affectsResolvedVersion`) on `get_package`, and the `advisories` row on `compare_packages`. A failed fetch omits the field rather than failing the call.

**SDK Release Notes**: Structured, version-by-version change descriptions for the Dart SDK or Flutter SDK/framework, retrieved from upstream `CHANGELOG.md` files via `get_sdk_release_notes`.
_Avoid_: release doc, changelog document

**SDK Release Notes Entry**: One `get_sdk_release_notes` entry — `{ version, date?, changes, sections, breaking }` with changes organized into category sections (e.g. `Language`, `Core libraries`, `Tools`, `Breaking changes`).

**OSV Affected Range**: One `affected[].ranges[]` entry — ordered range events (`introduced`, `fixed`, `last_affected`, `limit`). Evaluated via `osvRangesAffectVersion` (`pub_semver`). `introduced: "0"` means "affected since the beginning."

### Errors

**Tool Error**: A failed `CallToolResult` (`isError: true`) with body `{ error: { code, message, retryable, suggestion?, suggestedNextStep?, details? } }`. See ADR 0002.

**Error Code**: `SCREAMING_SNAKE_CASE` failure category. Defined: `AMBIGUOUS_SYMBOL`, `SYMBOL_NOT_FOUND`, `PACKAGE_NOT_FOUND`, `DOCUMENTATION_NOT_FOUND`, `RATE_LIMITED`, `PACKAGE_TOO_LARGE`, `INVALID_ARGUMENT`, `SERVICE_UNAVAILABLE`, `REQUEST_TIMEOUT`, `NO_DOCUMENTATION`, `UNEXPECTED_RESPONSE`.

### Caching and infrastructure

**Tarball Disk Cache**: LRU on-disk store of `.tar.gz` archives keyed by `{name}@{version}`. Default `~/.cache/dart_pubdev_mcp/`, 500 MB cap, 50 MB per-download limit (else `PACKAGE_TOO_LARGE`). Survives restarts.

**Cache Hit / Cache Miss / Uncached Call**: A `ResponseCache.get()` returning a live entry (Hit) or none/expired (Miss), vs. a pub.dev call with no cache in front at all (Uncached Call) — the latter two render identically in the Wire Trace.

**Package Info Cache**: `PubDevClient`'s cache for `GET /api/packages/{name}`, keyed by name, TTL 15 min. Shared across `resolveLatestStable`, `getPackage`, `listVersions`, `search`.
 
**SDK Changelog Cache**: In-memory cache for raw SDK `CHANGELOG.md` text, keyed by SDK (`dart` / `flutter`), TTL 24 hours. Falls back to extracting `CHANGELOG.md` from `TarballDiskCache` when an SDK tarball is cached locally.

### Observability

**Wire Trace**: Human-readable log of every message crossing the LLM boundary and pub.dev boundary, tagged with a Correlation Id. Written live to its own file; bodies are size-capped previews. Distinct from the client-facing MCP `log()`/`--log-level` mechanism.

**Correlation Id**: Short token (e.g. `#a3f`) tying one inbound request to every pub.dev call it triggers, via a Dart `Zone`.

### Tool outputs

**Comparison Matrix**: `compare_packages` output — every hard metric (scores, platforms, sdk constraints, deps, maintenance signals, advisories) mapped per package. No filtering; full matrix always returned.

**Non-Relevance Sort**: `search_packages` `sort` values other than `relevance` (`likes`, `pub_points`, `updated`) rank pub.dev's whole catalog by that metric, not by match to `query` — confirmed live (query `"csv"` + `sort: "likes"` returned unrelated top results). Documented in the tool description, not a bug.
