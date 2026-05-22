/// All ToolDefinitions and server instructions for pubdev_context.
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
    'Package discovery: search_packages → get_package → pub://package/{name}/readme. '
    'API exploration: search_api_symbols (one symbol at a time) → get_symbol_documentation → get_package_source_file if implementation details are missing. '
    'Upgrade analysis: get_changelog with from_version set → inspect breaking flags → rewrite affected code. '
    'Package comparison: search_packages → compare_packages on the top candidates. '
    'Every error response carries a machine-readable code and a suggestion field. Read suggestion before retrying. '
    'Resources: read pub://meta/resources first to see all available URIs. '
    'pub://meta/scoring — pub.dev 160-point scoring rubric. '
    'pub://meta/sdk-versions — current stable Dart and Flutter SDK versions (JSON). '
    'pub://package/{name}/readme — full README for a package (text/markdown). '
    'pub://package/{name}/example — working example code for a package (text/markdown). '
    'pub://package/{name}/changelog — full raw changelog for a package (text/markdown). '
    'pub://package/{name}/api — dartdoc symbol index for a package (JSON).';

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
      'For the full README, read pub://package/{name}/readme — the excerpt here is truncated. '
      'Do not call this with a guessed name — use search_packages first.',
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
      'For the full unstructured changelog text, read pub://package/{name}/changelog instead.',
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

// ─── search_api_symbols ───────────────────────────────────────────────────────

/// The `search_api_symbols` [Tool] definition registered with the MCP server.
final searchApiSymbolsTool = Tool(
  name: 'search_api_symbols',
  description:
      'Search for one symbol name at a time — multi-term queries like "PromptsSupport addPrompt" will not match. '
      'Use the href from the result to call get_symbol_documentation for the full signature and doc comment. '
      'Use type to narrow results when you know the symbol kind (class, method, enum, etc.). '
      'Call get_package first if you are not certain the package name is correct.',
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
    },
  ),
);

// ─── get_symbol_documentation ─────────────────────────────────────────────────

/// The `get_symbol_documentation` [Tool] definition registered with the MCP server.
final getSymbolDocumentationTool = Tool(
  name: 'get_symbol_documentation',
  description:
      'Call search_api_symbols first to get the href, then pass it directly here to read the full signature and doc comment. '
      'Use this to understand parameter types, return types, and usage notes for an API symbol. '
      'If the doc comment does not cover thrown exceptions or internal behavior, call get_package_source_file next.',
  inputSchema: ObjectSchema(
    required: ['package', 'href'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name, same as used in search_api_symbols.',
      ),
      'href': Schema.string(
        description:
            'Relative documentation path from the href field in a search_api_symbols result '
            '(e.g. "http/Client-class.html"). Pass it without modification.',
      ),
    },
  ),
);

// ─── get_package_source_file ──────────────────────────────────────────────────

/// The `get_package_source_file` [Tool] definition registered with the MCP server.
final getPackageSourceFileTool = Tool(
  name: 'get_package_source_file',
  description:
      'Call this when get_symbol_documentation does not expose implementation details '
      'such as thrown exceptions, internal branching logic, or undocumented invariants. '
      'Derive the file path from the href returned by search_api_symbols. '
      'On source_file_not_found, read the suggestion field — it lists the closest filename matches. '
      'If the suggestion is not sufficient, call list_package_source_files to browse the full file tree.',
  inputSchema: ObjectSchema(
    required: ['name', 'path'],
    properties: {
      'name': Schema.string(description: 'The pub.dev package name.'),
      'path': Schema.string(
        description:
            'File path relative to the package root '
            '(e.g. "lib/src/server/prompts_support.dart"). '
            'Derive it from the search_api_symbols href. '
            'Leading slash is stripped automatically. ".." segments are rejected.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
    },
  ),
);

// ─── list_package_source_files ────────────────────────────────────────────────

/// The `list_package_source_files` [Tool] definition registered with the MCP server.
final listPackageSourceFilesTool = Tool(
  name: 'list_package_source_files',
  description:
      'Call this only when get_package_source_file returns source_file_not_found and the suggestion does not name the right file. '
      'Set directory and fileExtension to narrow the listing before reading individual files. '
      'Select a path from the result and pass it to get_package_source_file.',
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
