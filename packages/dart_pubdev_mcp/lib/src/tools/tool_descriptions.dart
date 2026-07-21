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
    'Upgrade analysis: get_changelog with fromVersion set → inspect breaking flags → '
    'list_package_versions for concrete version strings → '
    'get_api_diff for the symbol-level delta between two known versions. '
    'Package comparison: search_packages → compare_packages on the top candidates. '
    'Dart/Flutter SDK source (dart:core, dart:async, package:flutter, …, not published on pub.dev): '
    'list_sdk_source_files to discover a file path when unknown, then get_sdk_throw_statements '
    'for exception surface, then get_sdk_source_slice for implementation detail. '
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
    'Call this first whenever you need a package name or want to discover packages for a use case. '
    'Never guess a package name — always search first. '
    'Each result is a package summary — name, description, and score/maintenance signals '
    '(e.g. likes, pubPoints, popularity, daysSinceUpdate) — not the full metadata get_package returns '
    '(dependencies, SDK constraints, README excerpt). '
    'Pass the resulting names to get_package for full details, or to compare_packages to evaluate alternatives. '
    "Set sdk and platform when the user's environment is known to avoid irrelevant results. "
    'It never returns version lists or API symbols — use list_package_versions or '
    'browse_api_symbols/find_symbols for those.';

// ─── get_package ──────────────────────────────────────────────────────────────

/// Description for `getPackageTool`.
const kGetPackageDescription =
    'Call this after search_packages to read full metadata for a specific package. '
    "Check scores, SDK constraints, and dependency count to evaluate fitness for the user's project. "
    'For the full README, read pub://package/{name}@{version}/readme (use @latest) — the excerpt here is truncated. '
    'Do not call this with a guessed name — use search_packages first. '
    'It never returns changelog entries or API symbols — use get_changelog and '
    'browse_api_symbols/find_symbols for those.';

// ─── get_changelog ────────────────────────────────────────────────────────────

/// Description for `getChangelogTool`.
const kGetChangelogDescription =
    'Call this when the user is upgrading a dependency or needs to check for breaking changes. '
    'Set fromVersion to the currently installed version to skip entries you already know. '
    'Check the breaking flag on each entry — flagged entries require code changes before upgrading. '
    'For the full unstructured changelog text, read pub://package/{name}@{version}/changelog (use @latest) instead. '
    'It does not detect API-level changes — pair with get_api_diff for a symbol-level diff.';

// ─── browse_api_symbols ───────────────────────────────────────────────────────

/// Description for `browseApiSymbolsTool`.
const kBrowseApiSymbolsDescription =
    'Use this only when you do not yet know the symbol name and want to narrow by symbol kind. '
    'When the name is already known, call `get_symbol_documentation` directly. '
    'Search for one symbol name at a time — multi-term queries like "PromptsSupport addPrompt" will not match. '
    'Use kind to narrow results when you know the symbol kind (class, method, enum, etc.). '
    'Prefer find_symbols instead for fuzzy, multi-token discovery across names and descriptions — '
    'it shares the same dartdoc index, so switching costs no extra fetch, but find_symbols has no kind filter. '
    'Call get_package first if you are not certain the package name is correct.';

// ─── find_symbols ─────────────────────────────────────────────────────────────

/// Description for `findSymbolsTool`.
const kFindSymbolsDescription =
    "Search a package's public API for symbols matching a query — the fuzzy, multi-token discovery "
    'counterpart to browse_api_symbols, which does plain substring matching narrowable by kind. '
    'Backed by the same dartdoc index as browse_api_symbols, so a warm index '
    'serves both without an extra download. '
    'Matching is a case-insensitive substring match on symbol names, falling back to a token-based '
    'fuzzy match against descriptions (multi-word queries match regardless of token order); name '
    'matches rank first. '
    'Results are capped at 20; hasMore: true is returned when more matches exist. '
    'Prefer browse_api_symbols instead when you know the symbol kind (class, method, enum, etc.) '
    'and want to filter by it — this tool has no kind filter. '
    'Call get_package first if you are not certain the package name is correct.';

// ─── get_symbol_documentation ─────────────────────────────────────────────────

/// Description for `getSymbolDocumentationTool`.
const kGetSymbolDocumentationDescription =
    'Call this to read the full signature and doc comment for a known symbol. '
    'Pass the short name ("Client") or a qualified name ("Client.send") — the server resolves it automatically. '
    'Use browse_api_symbols first only when the symbol name is unknown. '
    'Use this to understand parameter types, return types, and usage notes for an API symbol. '
    'If the result is AMBIGUOUS_SYMBOL, pick a qualifiedName from error.details.candidates and retry. '
    'If the doc comment does not cover thrown exceptions, call get_throw_statements next. '
    'If you still need broader implementation details or the canonical file and line numbers, '
    'call get_source_slice next.';

// ─── get_source_slice ─────────────────────────────────────────────────────────

/// Description for `getSourceSliceTool`.
const kGetSourceSliceDescription =
    'Call this to read Dart source from a single package file, in one of two modes. '
    'Line-range mode: provide file with optional lineStart/lineEnd (1-based, inclusive) '
    'to read an exact range with no truncation; omit both bounds to read the whole file. '
    'Symbol-bounded mode: provide file and symbolName to extract a named declaration '
    'located via the analyzer AST — a top-level class, mixin, enum, extension, function, '
    'typedef, or variable by bare name (e.g. "Client"), or a member by "ClassName.member" '
    '(e.g. "Client.send"; use "new" for the unnamed constructor). '
    'Pass maxLines to cap a large symbol: the response is collapsed to the signature, '
    'opening brace, an omission comment, and closing brace, with truncated=true. '
    'effectiveLineEnd always reports the true last line of the region, even when truncated, '
    'so you can drill in with a follow-up line-range read. '
    'Derive the file path from the href returned by browse_api_symbols or find_symbols. '
    'On SOURCE_FILE_NOT_FOUND, read the suggestion field — it lists the closest filename matches. '
    'If the suggestion is not sufficient, call list_package_source_files to browse the full file tree. '
    "For a symbol's rendered signature and doc comment instead of raw source, "
    'use get_symbol_documentation.';

// ─── get_sdk_source_slice ─────────────────────────────────────────────────────

/// Description for `getSdkSourceSliceTool`.
const kGetSdkSourceSliceDescription =
    'Call this to read source from the Dart SDK (dart:core, dart:async, dart:io, …) or the '
    'Flutter SDK/framework (package:flutter, flutter_test, flutter_driver, …) — source '
    'neither published on pub.dev nor reachable by get_source_slice, in one of two modes. '
    'For sdk: "dart", provide library (the dart: library name, e.g. "core") and file (the '
    "path within that library's directory, e.g. \"list.dart\" for dart:core's List "
    'implementation). '
    'For sdk: "flutter", provide package (e.g. "flutter") and file (the path within that '
    'package\'s lib/ directory, e.g. "src/widgets/framework.dart"). '
    'Line-range mode: pass optional lineStart/lineEnd (1-based, inclusive) to read an exact '
    'range; omit both bounds to read the whole file. '
    'Symbol-bounded mode: pass symbolName to extract a named declaration located via the '
    'analyzer AST — a top-level class, mixin, enum, extension, function, typedef, or variable '
    'by bare name (e.g. "State"), or a member by "ClassName.member" (e.g. "State.setState"; '
    'use "new" for the unnamed constructor). Pass maxLines to cap a large symbol: the response '
    'is collapsed to the signature, opening brace, an omission comment, and closing brace, '
    'with truncated=true. effectiveLineEnd always reports the true last line of the region, '
    'even when truncated, so you can drill in with a follow-up line-range read. '
    'Omit version to auto-detect: the Dart SDK version this server is running under, or the '
    "local Flutter install's framework version (found via FLUTTER_ROOT or PATH); pass an "
    'explicit tag or commit SHA to pin a different version. '
    'A Flutter request with no local install found and no explicit version surfaces '
    'SDK_NOT_DETECTED — set FLUTTER_ROOT, add flutter to PATH, or pass version explicitly.';

// ─── list_sdk_source_files ────────────────────────────────────────────────────

/// Description for `listSdkSourceFilesTool`.
const kListSdkSourceFilesDescription =
    'Call this to browse available file paths in the Dart SDK (dart:core, dart:async, …) or '
    'the Flutter SDK/framework (package:flutter, flutter_test, …) — the SDK-source counterpart '
    'to list_package_source_files. '
    'For sdk: "dart", set library (e.g. "core") to list only that dart: library\'s files; omit '
    'it to list every file in the SDK. '
    'For sdk: "flutter", set package (e.g. "flutter", "flutter_test") to list only that '
    "package's files; omit it to list every file across every Flutter package. "
    'Select a path from the result and pass it to get_sdk_source_slice as file (relative to '
    "the library's or package's lib/ directory). "
    'Omit version to auto-detect, matching get_sdk_source_slice.';

// ─── list_package_source_files ────────────────────────────────────────────────

/// Description for `listPackageSourceFilesTool`.
const kListPackageSourceFilesDescription =
    'Call this only when get_source_slice returns SOURCE_FILE_NOT_FOUND and the suggestion does not name the right file. '
    'Set directory and fileExtension to narrow the listing before reading individual files. '
    'Select a path from the result and pass it to get_source_slice. '
    'It never returns file contents — pass a chosen path to get_source_slice for that.';

// ─── get_throw_statements ─────────────────────────────────────────────────────

/// Description for `getThrowStatementsTool`.
const kGetThrowStatementsDescription =
    'Call this to find every `throw` expression in a class or function — '
    'each result includes the thrown type and the surrounding control-flow context. '
    'Use when you need to answer "what can this throw?" without loading entire source files. '
    'Provide `class` to scan all methods in a class; '
    'provide `class` + `method` to scan one method; '
    'provide only `method` to scan a top-level function. '
    'At least one of `class` or `method` is required. '
    'On AMBIGUOUS_SYMBOL for a top-level function, '
    'pick a qualifiedName from error.details.candidates and pass it as `method`. '
    'This is a static scan of throw expressions in source — it does not execute the code '
    'or report exceptions actually raised at runtime.';

// ─── get_sdk_throw_statements ──────────────────────────────────────────────────

/// Description for `getSdkThrowStatementsTool`.
const kGetSdkThrowStatementsDescription =
    'Call this to find every `throw` expression in a class or function within the Dart SDK '
    '(dart:core, dart:async, …) or the Flutter SDK/framework (package:flutter, flutter_test, …) '
    '— the SDK-source counterpart to get_throw_statements. '
    'For sdk: "dart", provide library (the dart: library name, e.g. "core"). '
    'For sdk: "flutter", provide package (e.g. "flutter"). '
    'Provide `class` to scan all methods in a class; '
    'provide `class` + `method` to scan one method; '
    'provide only `method` to scan a top-level function — this scans every file in the '
    'selected library/package directly (no symbol index exists for SDK code), so '
    'AMBIGUOUS_SYMBOL here lists candidate file paths, not qualified names. '
    'At least one of `class` or `method` is required. '
    'Omit version to auto-detect, matching get_sdk_source_slice. '
    'This is a static scan of throw expressions in source — it does not execute the code '
    'or report exceptions actually raised at runtime.';

// ─── compare_packages ─────────────────────────────────────────────────────────

/// Description for `comparePackagesTool`.
const kComparePackagesDescription =
    'Call this after search_packages when the user is choosing between multiple candidates. '
    'Pass the top 2–5 names from search results directly. '
    'Returns a comparison matrix — one row per field (score, platform support, SDK constraints, '
    'dependency count, maintenance signals such as license, publisher, and days since last update) '
    'mapped to a value per package — for scanning candidates side by side. '
    'Failed packages appear in errors and are excluded from the matrix — do not retry them. '
    'It never compares API surfaces or README content — use get_symbol_documentation/get_api_diff '
    'or the readme resource for that level of detail.';

// ─── list_package_versions ────────────────────────────────────────────────────

/// Description for `listPackageVersionsTool`.
const kListPackageVersionsDescription =
    'Call this to list every published version of a package, split into '
    'stable, prerelease, and retracted buckets — each sorted newest-first. '
    'Each entry carries the version string and its publish date. '
    'Use it to inspect release cadence, find the newest stable or prerelease '
    'version, or spot retracted versions to avoid depending on. '
    'It carries no changelog content or API information — pair it with get_changelog or get_api_diff '
    'for that; get_api_diff requires two concrete version strings, which this tool is the source of.';

// ─── get_api_diff ─────────────────────────────────────────────────────────────

/// Description for `getApiDiffTool`.
const kGetApiDiffDescription =
    'Call this when the user is upgrading (or downgrading) between two known versions and needs '
    'to see what changed in the public API surface. '
    'Returns two sets — added and removed — each bucketed into libraries, classes, methods, and fields. '
    'The diff is purely presence-based (a symbol is in one version but not the other); '
    'it does NOT detect signature changes such as renamed parameters, changed return types, or nullability. '
    'Both fromVersion and toVersion are required — obtain concrete versions from list_package_versions. '
    'On DOCUMENTATION_NOT_FOUND, one version lacks dartdoc output; '
    'fall back to browse_api_symbols per version as the error suggests. '
    'For narrative release notes rather than a symbol-level diff, use get_changelog instead.';
