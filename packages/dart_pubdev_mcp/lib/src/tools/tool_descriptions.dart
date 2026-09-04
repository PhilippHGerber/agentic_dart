/// The LLM-facing prose for `dart_pubdev_mcp`: [kServerInstructions] plus
/// every tool's `description` string, extracted from `tool_definitions.dart`
/// so the wiring and the prose can be scanned and edited independently.
///
/// Parameter-level (`inputSchema`/`outputSchema`) description strings are not
/// part of this file — they stay inline in `tool_definitions.dart`, welded to
/// their `Schema` objects.
library;

// ─── Server ───────────────────────────────────────────────────────────────────

/// Instructions passed to the MCP client during the initialize handshake.
const kServerInstructions =
    'This server gives read-only access to packages published on pub.dev — not the '
    "user's local project, path/git dependencies, or private registries; it never "
    'publishes or edits dependencies. '
    'Never guess a package name — always call search_packages first when the exact name is uncertain. '
    'Package discovery: search_packages → get_package → pub://package/{name}@{version}/readme. '
    'API exploration: get_symbol_documentation directly when the symbol name is known; '
    'otherwise browse_api_symbols or find_symbols to locate it, then get_throw_statements, '
    'then get_source_slice for implementation detail (list_package_source_files first when '
    'the file path is unknown). '
    'Archives are indexed in full (tests, examples, pubspec, README too) — never fall back to a '
    'local pub cache for them. '
    'grep_package_source searches across the whole cached source tree for a literal or regex '
    'pattern — use it to find every call site of a symbol instead of enumerating files by hand. '
    'Upgrade analysis: get_changelog with fromVersion set → inspect breaking flags → '
    'list_package_versions for concrete version strings → '
    'get_api_diff for the symbol-level delta between two known versions. '
    'Package comparison: search_packages → compare_packages on the top candidates. '
    'Security: get_security_advisories evaluates known advisories against a specific version, '
    'splitting affecting from other — check it before recommending or upgrading to a version. '
    'Dart/Flutter SDK source (dart:core, dart:async, package:flutter, …, not published on pub.dev): '
    'get_sdk_release_notes retrieves structured release notes and breaking changes for Dart or Flutter SDKs. '
    'list_sdk_source_files to discover a file path when unknown, then get_sdk_throw_statements '
    'for exception surface, then get_sdk_source_slice for implementation detail. '
    'grep_sdk_source searches the whole cached SDK/framework source tree (Dart-only by default) '
    'for a literal or regex pattern. '
    'Every error response carries a machine-readable code and a suggestion field — read suggestion before retrying. '
    'Resources: read pub://meta/resources first to see all available URIs. '
    'pub://meta/scoring — pub.dev 160-point scoring rubric. '
    'pub://meta/sdk-versions — current stable Dart and Flutter SDK versions (JSON). '
    'Package resource URIs require an explicit @{version} segment; use @latest for the Latest Stable Version. '
    'Every package resource body begins with a [Resolved Version: x.y.z] header line. '
    'pub://package/{name}@{version}/readme — full README for a package (text/markdown). '
    'pub://package/{name}@{version}/example — working example code for a package (text/markdown). '
    'pub://package/{name}@{version}/changelog — full raw changelog for a package (text/markdown). '
    'pub://package/{name}@{version}/api — dartdoc symbol index for a package (JSON). '
    'pub://package/{name}@{version}/pubspec — raw pubspec.yaml for a package (text/plain).';

// ─── search_packages ──────────────────────────────────────────────────────────

/// Description for `searchPackagesTool`.
const kSearchPackagesDescription =
    'Search pub.dev by keywords or qualifiers (publisher:, dependency:, topic:, license:, has:, sdk:). '
    'Always search to discover exact package names rather than guessing. '
    'Filter by sdk or platform to narrow results; keep sort: "relevance" when using qualifiers. '
    'Returns package summaries with scores and maintenance signals. '
    'Follow up with get_package for full metadata/dependencies, compare_packages for side-by-side evaluation, '
    'or find_symbols/browse_api_symbols for API exploration.';

// ─── get_package ──────────────────────────────────────────────────────────────

/// Description for `getPackageTool`.
const kGetPackageDescription =
    'Fetch full metadata for a specific pub.dev package and optional version. '
    'Returns scores, SDK constraints, runtime/dev dependencies, supported platforms, publisher, and advisory summary. '
    'Read pub://package/{name}@{version}/readme for complete README text. '
    'Follow up with get_security_advisories for CVE/GHSA details, get_changelog for release notes, '
    'or find_symbols/browse_api_symbols for API details.';

// ─── get_changelog ────────────────────────────────────────────────────────────

/// Description for `getChangelogTool`.
const kGetChangelogDescription =
    'Fetch structured changelog entries and breaking-change flags for a package. '
    'Set fromVersion to retrieve changes newer than a baseline version, or version to anchor to a specific release. '
    'Returns parsed bullet points, raw markdown, and breaking flags per release. '
    'Read pub://package/{name}@{version}/changelog for full raw text; pair with get_api_diff for symbol-level API diffs.';

// ─── get_security_advisories ──────────────────────────────────────────────────

/// Description for `getSecurityAdvisoriesTool`.
const kGetSecurityAdvisoriesDescription =
    'Check security advisories (GHSA/CVE) for a package version. '
    'Evaluates OSV affected ranges against the target version, returning vulnerabilities partitioned into '
    '"affecting" (version is vulnerable) and "other" (unaffected versions). '
    'Returns advisory IDs, CVE aliases, summary, advisory URL, and affected ranges. Empty lists indicate no advisories.';

// ─── browse_api_symbols ───────────────────────────────────────────────────────

/// Description for `browseApiSymbolsTool`.
const kBrowseApiSymbolsDescription =
    'Browse public API symbols filtered by a single search term and symbol kind (class, method, enum, function, typedef, etc.). '
    'Use when narrowing by symbol type. '
    'Use find_symbols instead for multi-word or description fuzzy searches; '
    'call get_symbol_documentation directly when the symbol name is already known.';

// ─── find_symbols ─────────────────────────────────────────────────────────────

/// Description for `findSymbolsTool`.
const kFindSymbolsDescription =
    'Search public API symbols using fuzzy multi-token matching across symbol names and doc descriptions (capped at 20). '
    'Matches names first, then descriptions regardless of token order. '
    'Pass the resulting qualifiedName to get_symbol_documentation for signatures and docs; '
    'use browse_api_symbols instead when filtering by symbol kind.';

// ─── get_symbol_documentation ─────────────────────────────────────────────────

/// Description for `getSymbolDocumentationTool`.
const kGetSymbolDocumentationDescription =
    'Fetch full type signature and rendered dartdoc documentation for a known API symbol. '
    'Accepts short names (Client), member names (Client.send), or fully-qualified names (http.Client.send). '
    'On AMBIGUOUS_SYMBOL error, retry using a candidate qualifiedName from error.details.candidates. '
    'Follow up with get_throw_statements for exceptions or get_source_slice for implementation source.';

// ─── get_source_slice ─────────────────────────────────────────────────────────

/// Description for `getSourceSliceTool`.
const kGetSourceSliceDescription =
    "Read any file from a package's published archive (Dart source, pubspec.yaml, README, tests, "
    'examples) in line-range or AST symbol-bounded mode. '
    'Line-range mode: specify path with optional lineStart/lineEnd (1-based, inclusive; omit bounds for entire file). '
    'Symbol-bounded mode: specify path and symbol (e.g. "Client", "Client.send", "new" for unnamed constructor) — '
    'Dart files only; '
    'maxLines truncates large bodies while reporting true lineEnd. '
    'Use list_package_source_files if the file path is unknown; use get_symbol_documentation for doc comments.';

// ─── get_sdk_source_slice ─────────────────────────────────────────────────────

/// Description for `getSdkSourceSliceTool`.
const kGetSdkSourceSliceDescription =
    'Read source code from the Dart SDK (dart:core, dart:async) or Flutter framework (package:flutter). '
    'Specify sdk: "dart" with library (e.g. "core") and path (e.g. "list.dart"), '
    'or sdk: "flutter" with package (e.g. "flutter") and path (e.g. "src/widgets/framework.dart"). '
    'Supports lineStart/lineEnd line ranges or symbol extraction (with optional maxLines). '
    'Auto-detects local SDK version when version is omitted. Use list_sdk_source_files to locate files.';

// ─── list_sdk_source_files ────────────────────────────────────────────────────

/// Description for `listSdkSourceFilesTool`.
const kListSdkSourceFilesDescription =
    'List source file paths in the Dart SDK or Flutter framework. '
    'For sdk: "dart", optionally filter by library (e.g. "core"); '
    'for sdk: "flutter", optionally filter by package (e.g. "flutter"). '
    'Filter results using directory path prefixes and fileExtension. '
    'Pass resulting paths to get_sdk_source_slice as path.';

// ─── list_package_source_files ────────────────────────────────────────────────

/// Description for `listPackageSourceFilesTool`.
const kListPackageSourceFilesDescription =
    "List every file in a package's published archive, lib/, test/, example/, bin/, plus "
    'pubspec.yaml, README, CHANGELOG and other non-Dart files. '
    'Filter results using directory path prefixes and fileExtension. '
    'Pass resulting paths to get_source_slice to read file contents.';

// ─── grep_package_source ──────────────────────────────────────────────────────

/// Description for `grepPackageSourceTool`.
const kGrepPackageSourceDescription =
    'Search a package source tree for a literal string (default) or Dart RegExp pattern (regex: true). '
    'The whole archive is searched, including test/ and example/. '
    'Scope searches using directory prefixes and fileExtension; set caseInsensitive: true or contextLines for surrounding lines. '
    'Binary files are excluded by default. Results are sorted by file/line and capped at 50 matches (hasMore: true).';

// ─── get_throw_statements ─────────────────────────────────────────────────────

/// Description for `getThrowStatementsTool`.
const kGetThrowStatementsDescription =
    'Statically extract throw and rethrow expressions from a package class (ClassName), member (ClassName.member), or top-level function. '
    'Returns static thrownType, enclosing symbol, file path, and surrounding code context. '
    'On AMBIGUOUS_SYMBOL error, supply a candidate qualifiedName from error.details.candidates.';

// ─── get_sdk_throw_statements ──────────────────────────────────────────────────

/// Description for `getSdkThrowStatementsTool`.
const kGetSdkThrowStatementsDescription =
    'Statically extract throw and rethrow expressions from the Dart SDK or Flutter framework. '
    'Provide sdk: "dart" with library (e.g. "core") or sdk: "flutter" with package (e.g. "flutter"), '
    'along with required symbol (class, member, or function). '
    'Returns static thrownType, enclosing symbol, file path, and surrounding code context.';

// ─── grep_sdk_source ──────────────────────────────────────────────────────────

/// Description for `grepSdkSourceTool`.
const kGrepSdkSourceDescription =
    'Search Dart SDK or Flutter framework sources for a literal string (default) or RegExp pattern (regex: true). '
    'Scope by sdk ("dart" with optional library, or "flutter" with optional package), directory prefix, or fileExtension (defaults to .dart). '
    'Supports caseInsensitive: true and contextLines. Results capped at 50 matches (hasMore: true).';

// ─── compare_packages ─────────────────────────────────────────────────────────

/// Description for `comparePackagesTool`.
const kComparePackagesDescription =
    'Compare 2–5 packages side-by-side across scores, platforms, SDK constraints, dependencies, maintenance signals, and security advisories. '
    'Returns a metric-by-package matrix; failed packages are reported in errors. '
    'Use get_api_diff or get_symbol_documentation for API comparison; read pub://package/{name}@{version}/readme for full READMEs.';

// ─── list_package_versions ────────────────────────────────────────────────────

/// Description for `listPackageVersionsTool`.
const kListPackageVersionsDescription =
    'List all published versions of a package partitioned into stable, prerelease, and retracted buckets (sorted newest-first). '
    'Returns version strings and publishedAt timestamps. '
    'Use to find available release versions before calling get_api_diff, get_changelog, or get_package.';

// ─── get_api_diff ─────────────────────────────────────────────────────────────

/// Description for `getApiDiffTool`.
const kGetApiDiffDescription =
    'Diff public API symbols between two concrete package versions (fromVersion to toVersion). '
    'Returns added and removed symbols categorized into libraries, classes, methods, and fields. '
    'Set includeSignatureChanges: true with symbol to compare AST declaration signatures across versions. '
    'Obtain version strings from list_package_versions; use get_changelog for narrative release notes.';

// ─── get_sdk_release_notes ───────────────────────────────────────────────────

/// Description for `getSdkReleaseNotesTool`.
const kGetSdkReleaseNotesDescription =
    'Retrieve structured release notes and changelogs for the Dart SDK (sdk: "dart") or Flutter framework (sdk: "flutter"). '
    'Set fromVersion to retrieve changes newer than a baseline version, or version to anchor to a specific release. '
    'Returns categorized sections, flat change lists, and breaking change flags per release.';
