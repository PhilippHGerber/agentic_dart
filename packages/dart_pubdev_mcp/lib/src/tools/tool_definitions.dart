/// All ToolDefinitions and server instructions for dart_pubdev_mcp.
///
/// This is the complete LLM-facing prompt surface of the server: the
/// [kServerInstructions] string passed during the MCP handshake, plus the
/// four [Tool] + [ObjectSchema] pairs that describe each tool's name,
/// description, and parameter descriptions.
///
/// Edit this file to tune how the server and its tools are presented to LLM
/// agents — no handler logic lives here.
library;

import 'package:dart_mcp/server.dart';

// ─── Server ───────────────────────────────────────────────────────────────────

/// Instructions passed to the MCP client during the initialize handshake.
const kServerInstructions =
    'You have access to the pub.dev Dart and Flutter package registry. '
    'Never guess a package name — always call search_packages first when the exact name is uncertain. '
    'Package discovery: search_packages → get_package → pub://package/{name}@{version}/readme. '
    'API exploration: call get_symbol_documentation directly when the symbol name is known; '
    'use browse_api_symbols only when the symbol name is unknown. '
    'For thrown exceptions, call get_throw_statements before loading full source files. '
    'Follow up with get_source_slice only when broader implementation details are still missing. '
    'Upgrade analysis: get_changelog with from_version set → inspect breaking flags → rewrite affected code; '
    'use get_api_diff to see which libraries, classes, methods, and fields were added or removed between two versions. '
    'Package comparison: search_packages → compare_packages on the top candidates. '
    'Every error response carries a machine-readable code and a suggestion field. Read suggestion before retrying. '
    'Resources: read pub://meta/resources first to see all available URIs. '
    'pub://meta/scoring — pub.dev 160-point scoring rubric. '
    'pub://meta/sdk-versions — current stable Dart and Flutter SDK versions (JSON). '
    'Package resource URIs require an explicit @{version} segment; use @latest for the Latest Stable Version. '
    'Every package resource body begins with a [Resolved Version: x.y.z] header line. '
    'pub://package/{name}@{version}/readme — full README for a package (text/markdown). '
    'pub://package/{name}@{version}/example — working example code for a package (text/markdown). '
    'pub://package/{name}@{version}/changelog — full raw changelog for a package (text/markdown). '
    'pub://package/{name}@{version}/api — dartdoc symbol index for a package (JSON).';

// ─── search_packages ──────────────────────────────────────────────────────────

/// The `search_packages` [Tool] definition registered with the MCP server.
final searchPackagesTool = Tool(
  name: 'search_packages',
  description:
      'Call this first whenever you need a package name or want to discover packages for a use case. '
      'Never guess a package name — always search first. '
      'Pass the resulting names to get_package for full details, or to compare_packages to evaluate alternatives. '
      "Set sdk and platform when the user's environment is known to avoid irrelevant results.",
  inputSchema: ObjectSchema(
    required: ['query'],
    properties: {
      'query': Schema.string(
        description:
            'Keyword or partial package name to search for. '
            'Try different keywords if results are empty or unexpected.',
      ),
      'limit': Schema.int(
        description:
            'Maximum number of results (default 5, max 20). '
            'Increase when collecting candidates for compare_packages.',
        minimum: 1,
        maximum: 20,
      ),
      'page': Schema.int(
        description: '1-indexed result page (default 1).',
        minimum: 1,
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description:
            'Restrict to packages supporting this SDK. Set when the target environment is known.',
        values: ['dart', 'flutter'],
      ),
      'sort': UntitledSingleSelectEnumSchema(
        description:
            'Sort order (default relevance). '
            'Use updated to find recently maintained packages; '
            'use likes or pub_points to find well-established ones.',
        values: ['relevance', 'likes', 'pub_points', 'updated'],
        defaultValue: 'relevance',
      ),
      'platform': UntitledSingleSelectEnumSchema(
        description:
            "Restrict to packages supporting this platform. Set when the user's target platform is known.",
        values: ['android', 'ios', 'web', 'linux', 'macos', 'windows'],
      ),
    },
  ),
);

// ─── get_package ──────────────────────────────────────────────────────────────

/// The `get_package` [Tool] definition registered with the MCP server.
final getPackageTool = Tool(
  name: 'get_package',
  description:
      'Call this after search_packages to read full metadata for a specific package. '
      "Check scores, SDK constraints, and dependency count to evaluate fitness for the user's project. "
      'For the full README, read pub://package/{name}@{version}/readme (use @latest) — the excerpt here is truncated. '
      'Do not call this with a guessed name — use search_packages first. '
      'The response includes a resolvedVersion field naming the exact version returned '
      '(the latest stable when version is omitted).',
  inputSchema: ObjectSchema(
    required: ['name'],
    properties: {
      'name': Schema.string(
        description: 'Exact package name on pub.dev. Obtain it from search_packages; never guess.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to fetch the latest published version.',
      ),
    },
  ),
);

// ─── get_changelog ────────────────────────────────────────────────────────────

/// The `get_changelog` [Tool] definition registered with the MCP server.
final getChangelogTool = Tool(
  name: 'get_changelog',
  description:
      'Call this when the user is upgrading a dependency or needs to check for breaking changes. '
      'Set from_version to the currently installed version to skip entries you already know. '
      'Check the breaking flag on each entry — flagged entries require code changes before upgrading. '
      'For the full unstructured changelog text, read pub://package/{name}@{version}/changelog (use @latest) instead. '
      'The response is an object with a resolvedVersion field '
      '(the latest stable when version is omitted) and an entries array.',
  inputSchema: ObjectSchema(
    required: ['name'],
    properties: {
      'name': Schema.string(
        description: 'Exact package name. Obtain it from search_packages or get_package.',
      ),
      'version_limit': Schema.int(
        description:
            'Maximum number of entries to return (default 5). '
            'Increase when from_version is many releases behind.',
      ),
      'from_version': Schema.string(
        description:
            'Return only entries newer than this version. '
            "Set this to the user's current version to skip already-known entries. "
            'If the exact version is absent, the first entry older than it is used as the boundary.',
      ),
    },
  ),
);

// ─── browse_api_symbols ───────────────────────────────────────────────────────

/// The `browse_api_symbols` [Tool] definition registered with the MCP server.
final browseApiSymbolsTool = Tool(
  name: 'browse_api_symbols',
  description:
      'Use this only when you do not yet know the symbol name. When the name is already known, call `get_symbol_documentation` directly. '
      'Search for one symbol name at a time — multi-term queries like "PromptsSupport addPrompt" will not match. '
      'Use type to narrow results when you know the symbol kind (class, method, enum, etc.). '
      'Call get_package first if you are not certain the package name is correct. '
      'The response is an object with a resolvedVersion field '
      '(the latest stable when version is omitted) and a symbols array.',
  inputSchema: ObjectSchema(
    required: ['package', 'query'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name. Verify with get_package if uncertain.',
      ),
      'query': Schema.string(
        description:
            'A single symbol name or keyword to search for. '
            'Do not combine a class name with a method name in one query.',
      ),
      'type': Schema.string(
        description:
            'Filter by dartdoc symbol kind. '
            'Known values: class, mixin, enum, function, constant, method, property, '
            'extension, accessor, constructor, typedef, library. '
            'Omit to return all matching symbol kinds. '
            'Unknown values are accepted without error.',
      ),
      'limit': Schema.int(
        description: 'Maximum number of results to return (default 10, max 25).',
        minimum: 1,
        maximum: 25,
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
    },
  ),
);

// ─── find_symbols ─────────────────────────────────────────────────────────────

/// The `find_symbols` [Tool] definition registered with the MCP server.
final findSymbolsTool = Tool(
  name: 'find_symbols',
  description:
      "Search a package's public API for symbols matching a query. "
      'Backed by the same dartdoc index as browse_api_symbols, so a warm index '
      'serves both without an extra download. '
      'Matching is a case-insensitive substring match on symbol names, falling '
      'back to a fuzzy match against short descriptions; name matches rank first. '
      'Results are capped at 20; hasMore: true is returned when more matches exist. '
      'Call get_package first if you are not certain the package name is correct. '
      'The response is an object with a resolvedVersion field '
      '(the latest stable when version is omitted) and a symbols array.',
  inputSchema: ObjectSchema(
    required: ['package', 'query'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name. Verify with get_package if uncertain.',
      ),
      'query': Schema.string(
        description:
            'A symbol name or keyword to search for. Matched case-insensitively '
            'against symbol names first, then against short descriptions.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
    },
  ),
);

// ─── get_symbol_documentation ─────────────────────────────────────────────────

/// The `get_symbol_documentation` [Tool] definition registered with the MCP server.
final getSymbolDocumentationTool = Tool(
  name: 'get_symbol_documentation',
  description:
      'Call this to read the full signature and doc comment for a known symbol. '
      'Pass the short name ("Client") or a qualified name ("Client.send") — the server resolves it automatically. '
      'Use browse_api_symbols first only when the symbol name is unknown. '
      'Use this to understand parameter types, return types, and usage notes for an API symbol. '
      'If the result is AMBIGUOUS_SYMBOL, pick a qualifiedName from error.details.candidates and retry. '
      'If the doc comment does not cover thrown exceptions, call get_throw_statements next. '
      'If you still need broader implementation details, call get_source_slice next. '
      'The response includes a resolvedVersion field naming the exact version used '
      '(the latest stable when version is omitted).',
  inputSchema: ObjectSchema(
    required: ['package', 'symbol'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name. Verify with get_package if uncertain.',
      ),
      'symbol': Schema.string(
        description:
            'The symbol name to look up. Accepted forms, in resolution order: '
            '(1) full qualifiedName (e.g. "http.Client") — use this when retrying after AMBIGUOUS_SYMBOL; '
            '(2) short name (e.g. "Client"); '
            '(3) qualified suffix without library prefix (e.g. "Client.send"). '
            'On AMBIGUOUS_SYMBOL, pick any value from error.details.candidates and pass it here.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
    },
  ),
);

// ─── get_source_slice ─────────────────────────────────────────────────────────

/// The `get_source_slice` [Tool] definition registered with the MCP server.
final getSourceSliceTool = Tool(
  name: 'get_source_slice',
  description:
      'Call this to read Dart source from a single package file, in one of two modes. '
      'Line-range mode: provide file with optional lineStart/lineEnd (1-based, inclusive) '
      'to read an exact range with no truncation; omit both bounds to read the whole file. '
      'Symbol-bounded mode: provide file and symbolName to extract a named declaration '
      'located via the analyzer AST — a top-level class, mixin, enum, extension, function, '
      'typedef, or variable by bare name (e.g. "Client"), or a member by "ClassName.member" '
      '(e.g. "Client.send"; use "new" for the unnamed constructor). '
      'Pass maxLines to cap a large symbol: the response is collapsed to the signature, '
      'opening brace, an omission comment, and closing brace, with truncated=true. '
      'Every response includes resolvedVersion, truncated, and effectiveLineEnd (the true '
      'last line of the region) so you can drill in with a follow-up line-range read. '
      'Derive the file path from the href returned by browse_api_symbols or find_symbols. '
      'On SOURCE_FILE_NOT_FOUND, read the suggestion field — it lists the closest filename matches. '
      'If the suggestion is not sufficient, call list_package_source_files to browse the full file tree.',
  inputSchema: ObjectSchema(
    required: ['package', 'file'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name. Verify with get_package if uncertain.',
      ),
      'file': Schema.string(
        description:
            'File path relative to the package root '
            '(e.g. "lib/src/server/prompts_support.dart"). '
            'Derive it from a browse_api_symbols or find_symbols href. '
            'Leading slash is stripped automatically. ".." segments are rejected.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest stable version.',
      ),
      'lineStart': Schema.int(
        description:
            'Line-range mode: 1-based inclusive first line. '
            'Omit with lineEnd to return the full file.',
      ),
      'lineEnd': Schema.int(
        description: 'Line-range mode: 1-based inclusive last line.',
      ),
      'symbolName': Schema.string(
        description:
            'Symbol-bounded mode: the declaration to extract. '
            'A bare name (e.g. "Client") matches a top-level declaration; '
            '"ClassName.member" (e.g. "Client.send") matches a class member. '
            'Use "new" for the unnamed constructor; "==" or "operator ==" for operators. '
            'When provided, lineStart/lineEnd are ignored.',
      ),
      'maxLines': Schema.int(
        description:
            'Symbol-bounded mode: truncate the symbol to signature + closing brace '
            'when it spans more than this many lines. Omit for the full symbol body.',
      ),
    },
  ),
);

// ─── list_package_source_files ────────────────────────────────────────────────

/// The `list_package_source_files` [Tool] definition registered with the MCP server.
final listPackageSourceFilesTool = Tool(
  name: 'list_package_source_files',
  description:
      'Call this only when get_source_slice returns SOURCE_FILE_NOT_FOUND and the suggestion does not name the right file. '
      'Set directory and fileExtension to narrow the listing before reading individual files. '
      'Select a path from the result and pass it to get_source_slice. '
      'The response is an object with a resolvedVersion field '
      '(the latest stable when version is omitted), the package name, and a files array.',
  inputSchema: ObjectSchema(
    required: ['name'],
    properties: {
      'name': Schema.string(description: 'The pub.dev package name.'),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
      'directory': Schema.string(
        description:
            'Path prefix filter (e.g. "lib/src/server/"). '
            'Set this to avoid scanning the full tree. '
            'Trailing slash is added automatically if absent.',
      ),
      'fileExtension': Schema.string(
        description:
            'Extension filter (e.g. ".dart"). '
            'AND-combined with directory when both are supplied.',
      ),
    },
  ),
);

// ─── get_throw_statements ─────────────────────────────────────────────────────

/// The `get_throw_statements` [Tool] definition registered with the MCP server.
final getThrowStatementsTool = Tool(
  name: 'get_throw_statements',
  description:
      'Call this to find every `throw` expression in a class or function — '
      'each result includes the thrown type and the surrounding control-flow context. '
      'Use when you need to answer "what can this throw?" without loading entire source files. '
      'Provide `class` to scan all methods in a class; '
      'provide `class` + `method` to scan one method; '
      'provide only `method` to scan a top-level function. '
      'At least one of `class` or `method` is required. '
      'On AMBIGUOUS_SYMBOL for a top-level function, '
      'pick a qualifiedName from error.details.candidates and pass it as `method`. '
      'The response is an object with a resolvedVersion field '
      '(the latest stable when version is omitted) and a throws array.',
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name. Verify with get_package if uncertain.',
      ),
      'class': Schema.string(
        description:
            'The class, mixin, enum, or extension name to scan. '
            'Omit to scan a top-level function instead. '
            'Provide without `method` to scan all throws in the entire class.',
      ),
      'method': Schema.string(
        description:
            'The method or top-level function name to scan. '
            'When combined with `class`, scans that specific method only. '
            'For operators, pass either "==" or "operator ==". '
            'For the default (unnamed) constructor, pass "new". '
            'For named constructors, pass only the constructor suffix (e.g. "fromJson"). '
            'When `class` is omitted, treats this as a top-level function name. '
            'On AMBIGUOUS_SYMBOL, pass the full qualifiedName from error.details.candidates.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
    },
  ),
);

// ─── compare_packages ─────────────────────────────────────────────────────────

/// The `compare_packages` [Tool] definition registered with the MCP server.
final comparePackagesTool = Tool(
  name: 'compare_packages',
  description:
      'Call this after search_packages when the user is choosing between multiple candidates. '
      'Pass the top 2–5 names from search results directly. '
      'Use the scores, platform support, and maintenance signals to make a recommendation. '
      'Failed packages appear in errors and are excluded from the matrix — do not retry them.',
  inputSchema: ObjectSchema(
    required: ['names'],
    properties: {
      'names': Schema.list(
        description: 'Package names to compare (2–5 entries). Obtain them from search_packages.',
        items: Schema.string(description: 'A pub.dev package name.'),
        minItems: 2,
        maxItems: 5,
      ),
    },
  ),
);

// ─── list_package_versions ────────────────────────────────────────────────────

/// The `list_package_versions` [Tool] definition registered with the MCP server.
final listPackageVersionsTool = Tool(
  name: 'list_package_versions',
  description:
      'Call this to list every published version of a package, split into '
      'stable, prerelease, and retracted buckets — each sorted newest-first. '
      'Each entry carries the version string and its publish date. '
      'Use it to inspect release cadence, find the newest stable or prerelease '
      'version, or spot retracted versions to avoid depending on.',
  inputSchema: ObjectSchema(
    required: ['name'],
    properties: {
      'name': Schema.string(
        description: 'The exact pub.dev package name. Obtain it from search_packages if unsure.',
      ),
    },
  ),
);

// ─── get_api_diff ─────────────────────────────────────────────────────────────

/// The `get_api_diff` [Tool] definition registered with the MCP server.
final getApiDiffTool = Tool(
  name: 'get_api_diff',
  description:
      'Call this when the user is upgrading (or downgrading) between two known versions and needs '
      'to see what changed in the public API surface. '
      'Returns two sets — added and removed — each bucketed into libraries, classes, methods, and fields. '
      'The diff is purely presence-based (a symbol is in one version but not the other); '
      'it does NOT detect signature changes such as renamed parameters, changed return types, or nullability. '
      'Both fromVersion and toVersion are required — obtain concrete versions from list_package_versions. '
      'On DOCUMENTATION_NOT_FOUND, one version lacks dartdoc output; '
      'fall back to browse_api_symbols per version as the error suggests.',
  inputSchema: ObjectSchema(
    required: ['package', 'fromVersion', 'toVersion'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name. Verify with get_package if uncertain.',
      ),
      'fromVersion': Schema.string(
        description:
            'The baseline version to diff from (e.g. "0.13.0"). '
            'Required — this tool does not resolve a latest-stable version.',
      ),
      'toVersion': Schema.string(
        description:
            'The target version to diff to (e.g. "1.2.0"). '
            'Required — this tool does not resolve a latest-stable version.',
      ),
    },
  ),
);
