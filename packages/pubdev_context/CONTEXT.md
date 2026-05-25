# pubdev_context

An MCP server that gives LLM agents structured, version-aware, token-efficient access to Dart and Flutter packages on pub.dev.

## Language

### Distribution units

**Package**:
A pub.dev distribution unit identified by name and version. Contains one or more libraries.
_Avoid_: Module, gem, dependency (for this concept)

**Library**:
A named Dart grouping (via the `library` directive or implicit file-level library) that forms the organizational unit within a package's public API. A package exposes one or more libraries.
_Avoid_: Module, namespace

**Symbol**:
A single named, documentable Dart declaration that dartdoc assigns a kind and indexes in `index.json`. Covers classes, methods, functions, constructors, enums, mixins, extensions, typedefs, accessors, and top-level constants/properties.
_Excludes_: Libraries and packages — those are distinct concepts.
_Avoid_: API element, declaration, member (use "member" only for class-scoped symbols when scope is clear)

### Versioning

**Latest Stable Version**:
The newest published version of a package that carries no pre-release segment (no `-alpha`, `-beta`, `-rc`, `-dev` suffix). Used as the automatic fallback whenever a caller omits `version`. Resolved from pub.dev's versions list at call time.
_Avoid_: Latest version (ambiguous — could include pre-releases)

**Resolved Version**:
A top-level field in the JSON response of any tool that accepts a `version` parameter (whether the caller supplied it or the server auto-resolved it). Value is the exact semver string used (e.g. `"1.2.0"`). Not present on version-agnostic tools (`search_packages`, `list_package_source_files`) or on `compare_packages` (which already includes `version` per package in the Comparison Matrix).
_Avoid_: Inferred version, effective version

**Package Resource URI**:
The canonical address of a versioned package artifact served by this server, e.g. `pub://package/http@1.2.0/readme`. Always includes an explicit `@{version}` segment; `latest` is a legal version value and resolves to the Latest Stable Version. The versionless form is not supported. See ADR 0001.
_Avoid_: Resource URL, resource path

**Version Listing**:
The output of `list_package_versions`: three bucketed lists — `stable`, `prerelease`, `retracted` — each sorted newest-first, each entry carrying the version string and `publishedAt` date. Version-level retraction status is included here; package-level discontinuation belongs on `get_package`. Post-V1: pagination / truncation for packages with 100+ versions.
_Avoid_: Version history, version catalog

### Symbols and source

**Symbol Identity**:
The exact, unambiguous address of a symbol: fully-qualified name + enclosing library URI + package version (e.g. `CueTimelineController`, `package:cue/cue.dart`, `1.2.0`). The output format returned by `find_symbols` and consumed by `get_symbol_documentation` and `get_source_slice`.
_Avoid_: Symbol reference, symbol path

**Symbol Search**:
A case-insensitive substring and fuzzy match against symbol names and short descriptions within a single package's dartdoc `index.json`. Requires an explicit package name; returns up to 20 Symbol Search Results with a `hasMore` flag. Backed by the same cached artifact as `browse_api_symbols`.
_Avoid_: Global symbol search, cross-package search (V1 is single-package only)

**Symbol Search Result**:
One entry in the output of `find_symbols`: `{ name, qualifiedName, kind, library, enclosedBy, description, href }`. `enclosedBy` is null for top-level symbols and holds the container name (e.g. a class name) for methods, constructors, and accessors.

**Source Slice**:
An extract of Dart source code from a package file, produced by `get_source_slice`. Two modes: (1) *line-range* — caller supplies `lineStart`/`lineEnd`, honored exactly with no truncation; (2) *symbol-bounded* — caller supplies a symbol name, server uses the AST to locate the node and applies optional `maxLines` truncation if the body exceeds the limit, returning `truncated: true` and `effectiveLineEnd` when cut.
_Avoid_: Source excerpt, code snippet (for this server's specific tool output)

**API Diff**:
The output of `get_api_diff`: sets of added and removed libraries, classes, fields, and methods between two package versions, computed by diffing the dartdoc `index.json` artifacts for each version. V1 limitation: no structural diff (parameter changes, nullability). If dartdoc is missing for either version the tool hard-fails with `DOCUMENTATION_NOT_FOUND` and a `suggestedNextStep` pointing to `browse_api_symbols` per version as a manual workaround.
_Avoid_: Breaking change report (the tool detects structural additions/removals, not semantic breaking changes)

### Errors

**Tool Error**:
A failed tool result returned via MCP `CallToolResult` with `isError: true`. Content is a single JSON block: `{ "error": { "code": "…", "message": "…", "retryable": bool, "suggestion": "…", "suggestedNextStep": {…}, "details": {…} } }`. `suggestedNextStep` and `details` are optional. See ADR 0002.
_Avoid_: Exception, thrown error (no Dart exceptions cross module boundaries), error string

**Error Code**:
A `SCREAMING_SNAKE_CASE` string identifying a failure category. Defined codes: `AMBIGUOUS_SYMBOL`, `SYMBOL_NOT_FOUND`, `PACKAGE_NOT_FOUND`, `DOCUMENTATION_NOT_FOUND`, `RATE_LIMITED`, `PACKAGE_TOO_LARGE`, `INVALID_ARGUMENT`, `SERVICE_UNAVAILABLE`, `REQUEST_TIMEOUT`, `NO_DOCUMENTATION`, `UNEXPECTED_RESPONSE`.
_Avoid_: Error type, error string, exception code

### Caching and infrastructure

**Tarball Disk Cache**:
An LRU, size-capped on-disk store of downloaded `.tar.gz` package archives, keyed by `{name}@{version}`. Default location: `~/.cache/pubdev_context/` (XDG cache dir), overridable via `--cache-dir`. Default cap: 500 MB. Per-tarball download limit: 50 MB; exceeded downloads abort and return a `PACKAGE_TOO_LARGE` Tool Error. Survives server restarts.
_Avoid_: File cache, package cache (ambiguous with in-memory caches)

### Tool outputs

**Comparison Matrix**:
The fixed output of `compare_packages`: a JSON object mapping every available hard metric (scores, platforms, sdk constraints, dependency count, maintenance signals, license, publisher) to a per-package value map. No caller-supplied criteria filter — the full matrix is always returned; the LLM selects what is relevant. Metrics requiring tarball access (`api-surface`, `example-quality`) are post-V1.
_Avoid_: Criteria matrix, filtered comparison

---

## Example dialogue

> **Dev:** I want to find the `StreamController` class in the `async` package — which tool do I use?
>
> **Expert:** `find_symbols` — it takes the package name and a query. The `package` argument is mandatory; the server returns `INVALID_ARGUMENT` immediately if you omit it. Pass `query: "StreamController"` and it searches the dartdoc index, returning a list of Symbol Search Results — name, kind, library, enclosedBy, and an href. Each result is a Symbol Identity you can hand straight to `get_symbol_documentation`.
>
> **Dev:** What if I just want to browse what's in the package without knowing a symbol name?
>
> **Expert:** That's `browse_api_symbols` — give it a package and a depth, it returns the API tree as an outline. `find_symbols` is query-driven; `browse_api_symbols` is structural exploration.
>
> **Dev:** If I call `get_source_slice` on a huge class and don't want the whole thing —
>
> **Expert:** Pass `maxLines`. The server returns the signature, opening brace, a truncation comment, and closing brace, with `truncated: true` and `effectiveLineEnd` so you know where it cut. If you need an exact range instead, use the line-range mode with `lineStart`/`lineEnd` — that's never truncated.
>
> **Dev:** I forgot to pass a version to `get_package` — what happens?
>
> **Expert:** The server resolves the Latest Stable Version — newest non-pre-release — and runs the call. The response always includes `resolvedVersion` as the first key so you know exactly which version was used. From there you can pin that version in all your follow-up calls.
