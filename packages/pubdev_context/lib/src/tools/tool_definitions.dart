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
    'Search, evaluate, and inspect Dart and Flutter packages on pub.dev. '
    'Use search_packages to discover packages by keyword. '
    'All errors carry a machine-readable code and a corrective suggestion.';

// ─── search_packages ──────────────────────────────────────────────────────────

/// The `search_packages` [Tool] definition registered with the MCP server.
final searchPackagesTool = Tool(
  name: 'search_packages',
  description:
      'Search pub.dev packages by keyword. '
      'Returns a list of PackageSummary records with scores, platform support, '
      'and maintenance signals. '
      'Use sdk/platform filters to narrow results for a specific environment.',
  inputSchema: ObjectSchema(
    required: ['query'],
    properties: {
      'query': Schema.string(description: 'Search keywords or a package name.'),
      'limit': Schema.int(
        description: 'Maximum number of results to return (default 5, max 20).',
        minimum: 1,
        maximum: 20,
      ),
      'page': Schema.int(
        description: '1-indexed result page (default 1).',
        minimum: 1,
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Filter by SDK compatibility.',
        values: ['dart', 'flutter'],
      ),
      'sort': UntitledSingleSelectEnumSchema(
        description:
            'Sort order (default relevance). '
            'Allowed: relevance | likes | pub_points | updated.',
        values: ['relevance', 'likes', 'pub_points', 'updated'],
        defaultValue: 'relevance',
      ),
      'platform': UntitledSingleSelectEnumSchema(
        description: 'Filter by platform support.',
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
      'Get full details for a pub.dev package. '
      'Returns a PackageDetail with scores, SDK constraints, dependencies, '
      'recent versions, and a README excerpt. '
      'Optionally pin a specific version with the version parameter. '
      'Use search_packages first to discover package names.',
  inputSchema: ObjectSchema(
    required: ['name'],
    properties: {
      'name': Schema.string(description: 'The package name on pub.dev.'),
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
      'Get recent changelog entries for a pub.dev package. '
      'Returns a list of ChangelogEntry records ordered newest-first, each with '
      'a version, changes text, and a breaking flag derived from the entry text. '
      'Use from_version to fetch only entries newer than a version you already know. '
      'Use search_packages or get_package first to discover package names.',
  inputSchema: ObjectSchema(
    required: ['name'],
    properties: {
      'name': Schema.string(description: 'The package name on pub.dev.'),
      'version_limit': Schema.int(
        description: 'Maximum number of changelog entries to return. Defaults to 5.',
      ),
      'from_version': Schema.string(
        description:
            'Exclusive lower bound. Returns only entries newer than this version. '
            'If the exact version string is not in the changelog, the first entry '
            'older than it is used as the boundary.',
      ),
    },
  ),
);

// ─── search_api_symbols ───────────────────────────────────────────────────────

/// The `search_api_symbols` [Tool] definition registered with the MCP server.
final searchApiSymbolsTool = Tool(
  name: 'search_api_symbols',
  description:
      'Search the dartdoc API symbol index of a pub.dev package. '
      'Returns a ranked list of DartdocSymbol records: exact name matches appear '
      'before description-only matches. '
      'Use the type parameter to narrow results to a specific symbol kind. '
      'Use get_package first to verify the package name.',
  inputSchema: ObjectSchema(
    required: ['package', 'query'],
    properties: {
      'package': Schema.string(description: 'The pub.dev package name.'),
      'query': Schema.string(
        description: 'Search term matched against symbol names and descriptions.',
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
      'Fetch the full dartdoc page for a specific API symbol from pub.dev. '
      'Call search_api_symbols first to obtain the package name and href for the symbol. '
      'Pass the href from that result directly to this tool to read the full signature, '
      'parameters, and doc comment as plain text.',
  inputSchema: ObjectSchema(
    required: ['package', 'href'],
    properties: {
      'package': Schema.string(description: 'The pub.dev package name.'),
      'href': Schema.string(
        description:
            'Relative documentation path returned by search_api_symbols '
            '(e.g. "http/Client-class.html").',
      ),
    },
  ),
);

// ─── get_package_source_file ──────────────────────────────────────────────────

/// The `get_package_source_file` [Tool] definition registered with the MCP server.
final getPackageSourceFileTool = Tool(
  name: 'get_package_source_file',
  description:
      'Return the content of a single source file from a pub.dev package tarball. '
      'Use this when get_symbol_documentation does not expose implementation details '
      'such as thrown exceptions, internal branching logic, or undocumented invariants. '
      'The dartdoc href from search_api_symbols gives a directional hint about the '
      'source directory. On source_file_not_found, the suggestion field lists closest '
      'filename matches or directs you to call list_package_source_files.',
  inputSchema: ObjectSchema(
    required: ['name', 'path'],
    properties: {
      'name': Schema.string(description: 'The pub.dev package name.'),
      'path': Schema.string(
        description:
            'File path relative to the package root '
            '(e.g. "lib/src/server/prompts_support.dart"). '
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
      'List file paths available in a pub.dev package tarball. '
      'Use directory and fileExtension to narrow results. '
      'The full file map is cached for 1 hour — listing after get_package_source_file '
      'for the same package version is free. '
      'Call this when get_package_source_file returns source_file_not_found and '
      'the closest-match suggestion is not sufficient.',
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
            'Optional path prefix filter (e.g. "lib/src/server/"). '
            'Trailing slash is added automatically if absent.',
      ),
      'fileExtension': Schema.string(
        description:
            'Optional extension filter (e.g. ".dart"). '
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
      'Compare 2–5 pub.dev packages side by side. '
      'Returns a ComparisonMatrix with scores, SDK constraints, platform support, '
      'maintenance signals, and dependency counts. '
      'Failed packages appear in errors and are excluded from the matrix. '
      'Use search_packages first to discover package names.',
  inputSchema: ObjectSchema(
    required: ['names'],
    properties: {
      'names': Schema.list(
        description: 'Package names to compare (2–5 entries).',
        items: Schema.string(description: 'A pub.dev package name.'),
        minItems: 2,
        maxItems: 5,
      ),
    },
  ),
);
