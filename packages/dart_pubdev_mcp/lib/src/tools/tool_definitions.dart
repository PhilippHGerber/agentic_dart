/// All ToolDefinitions and server instructions for dart_pubdev_mcp.
///
/// This is the complete LLM-facing prompt surface of the server: the
/// [kServerInstructions] string passed during the MCP handshake, plus the
/// [Tool] + [ObjectSchema] pairs that describe each tool's name, title,
/// description, annotations, parameter descriptions, and (for every tool but
/// `search_packages`) the `outputSchema` its `structuredContent` conforms to.
///
/// Edit this file to tune how the server and its tools are presented to LLM
/// agents — no handler logic lives here.
library;

import 'package:dart_mcp/server.dart';

/// Shared behavioural hints for every tool in this server: all 12 tools only
/// read pub.dev and the local package cache (`readOnlyHint: true`) and call
/// out over the network to an "open world" of packages (`openWorldHint:
/// true`, which matches the spec default — stated explicitly here to make
/// the intent audit-proof). `destructiveHint` and `idempotentHint` are
/// meaningful only when `readOnlyHint == false`, so they are left unset.
final kReadOnlyOpenWorldAnnotations = ToolAnnotations(
  readOnlyHint: true,
  openWorldHint: true,
);

// ─── Output schema helpers ──────────────────────────────────────────────────────

/// The `resolvedVersion` property shared by every `outputSchema` whose tool
/// accepts a `version` input — mirrors the Resolved Version invariant
/// documented in `CONTEXT.md`.
final StringSchema _kResolvedVersionSchema = Schema.string(
  description:
      'The exact semver version this response describes — the caller-supplied '
      'version, or the Latest Stable Version when version was omitted.',
);

/// A string property that is always present in the response but whose value
/// may be JSON `null` (as opposed to an optional property that is omitted
/// from the response entirely when absent).
Schema _nullableString(String description) =>
    Schema.combined(description: description, anyOf: [Schema.string(), Schema.nil()]);

/// The package-name echo property shared by output schemas that return the
/// pub.dev package name unchanged from the input.
final StringSchema _kPackageNameSchema = Schema.string(
  description: 'The pub.dev package name, as given.',
);

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
    'then get_source_slice for implementation detail. '
    'Upgrade analysis: get_changelog with fromVersion set → inspect breaking flags → '
    'get_api_diff for the symbol-level delta between two known versions. '
    'Package comparison: search_packages → compare_packages on the top candidates. '
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

/// The `search_packages` [Tool] definition registered with the MCP server.
///
/// The sole tool with no `outputSchema`: its response body is a bare JSON
/// array, but `CallToolResult.structuredContent` is typed as a JSON object —
/// wrapping the array to fit would change the wire contract, so this tool is
/// exempt rather than reshaped to accommodate it.
final searchPackagesTool = Tool(
  name: 'search_packages',
  title: 'Search pub.dev packages',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this first whenever you need a package name or want to discover packages for a use case. '
      'Never guess a package name — always search first. '
      'Each result is a package summary — name, description, and score/maintenance signals '
      '(e.g. likes, pubPoints, popularity, daysSinceUpdate) — not the full metadata get_package returns '
      '(dependencies, SDK constraints, README excerpt). '
      'Pass the resulting names to get_package for full details, or to compare_packages to evaluate alternatives. '
      "Set sdk and platform when the user's environment is known to avoid irrelevant results. "
      'It never returns version lists or API symbols — use list_package_versions or '
      'browse_api_symbols/find_symbols for those.',
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
            'Use updated to find recently maintained packages; use likes or pub_points to find '
            'well-established ones, but only with a loose or absent query — non-relevance sorts '
            'rank globally, so a narrow query can return top-ranked but unrelated packages.',
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
  title: 'Get package details',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this after search_packages to read full metadata for a specific package. '
      "Check scores, SDK constraints, and dependency count to evaluate fitness for the user's project. "
      'For the full README, read pub://package/{name}@{version}/readme (use @latest) — the excerpt here is truncated. '
      'Do not call this with a guessed name — use search_packages first. '
      'It never returns changelog entries or API symbols — use get_changelog and '
      'browse_api_symbols/find_symbols for those.',
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description: 'Exact package name on pub.dev. Obtain it from search_packages; never guess.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to fetch the latest published version.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: [
      'resolvedVersion',
      'name',
      'version',
      'description',
      'verified',
      'activeMaintenance',
      'likes',
      'pubPoints',
      'popularity',
      'sdkConstraints',
      'platforms',
      'topics',
      'isFlutterFavorite',
      'dependencies',
      'devDependencies',
      'versionsRecent',
    ],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'name': _kPackageNameSchema,
      'version': Schema.string(description: 'The package version described — equals resolvedVersion.'),
      'description': Schema.string(description: "The package's pub.dev listing description."),
      'verified': Schema.bool(description: "Whether the package's publisher domain is verified."),
      'publishedAt': Schema.string(
        description: 'ISO 8601 publish timestamp of this version. Omitted when pub.dev does not report one.',
      ),
      'activeMaintenance': Schema.bool(
        description: 'Whether the package has been updated recently enough to count as actively maintained.',
      ),
      'likes': Schema.int(description: 'Pub.dev like count.'),
      'pubPoints': Schema.int(description: 'Pub.dev pub points score (0–160).'),
      'popularity': Schema.int(description: '30-day download count used for the pub.dev popularity score.'),
      'sdkConstraints': Schema.object(
        description: 'SDK version constraints declared in the pubspec environment.',
        required: ['dart'],
        properties: {
          'dart': Schema.string(description: 'The Dart SDK constraint.'),
          'flutter': Schema.string(
            description: 'The Flutter SDK constraint. Omitted for pure-Dart packages.',
          ),
        },
      ),
      'platforms': Schema.list(
        description: 'Platforms this package declares support for.',
        items: Schema.string(),
      ),
      'topics': Schema.list(
        description: 'Pub.dev topic tags for this package.',
        items: Schema.string(),
      ),
      'isFlutterFavorite': Schema.bool(description: 'Whether pub.dev has flagged this package a Flutter Favorite.'),
      'dependencies': Schema.object(
        description: 'Runtime dependencies keyed by package name, with version constraint strings as values.',
        additionalProperties: Schema.string(),
      ),
      'devDependencies': Schema.object(
        description: 'Development dependencies keyed by package name, with version constraint strings as values.',
        additionalProperties: Schema.string(),
      ),
      'versionsRecent': Schema.list(
        description: 'A short list of recently published version strings, newest first.',
        items: Schema.string(),
      ),
      'publisher': Schema.string(description: 'The verified publisher domain. Omitted when unverified.'),
      'license': Schema.string(
        description: 'The first SPDX license identifier reported by pub.dev. Omitted when unknown.',
      ),
      'readmeExcerpt': Schema.string(
        description: 'A truncated excerpt of the README. Omitted when unavailable. '
            'Read pub://package/{name}@{version}/readme for the full text.',
      ),
      'repository': Schema.string(description: 'The source repository URL. Omitted when not declared.'),
    },
  ),
);

// ─── get_changelog ────────────────────────────────────────────────────────────

/// The `get_changelog` [Tool] definition registered with the MCP server.
final getChangelogTool = Tool(
  name: 'get_changelog',
  title: 'Get structured changelog',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this when the user is upgrading a dependency or needs to check for breaking changes. '
      'Set fromVersion to the currently installed version to skip entries you already know. '
      'Check the breaking flag on each entry — flagged entries require code changes before upgrading. '
      'For the full unstructured changelog text, read pub://package/{name}@{version}/changelog (use @latest) instead. '
      'It does not detect API-level changes — pair with get_api_diff for a symbol-level diff.',
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description: 'Exact package name. Obtain it from search_packages or get_package.',
      ),
      'limit': Schema.int(
        description:
            'Maximum number of entries to return (default 5). '
            'Increase when fromVersion is many releases behind.',
      ),
      'fromVersion': Schema.string(
        description:
            'Return only entries newer than this version (e.g. "1.2.0"). '
            "Set this to the user's current version to skip already-known entries. "
            'If the exact version is absent, the first entry older than it is used as the boundary.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'entries'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'entries': Schema.list(
        description: 'Changelog entries, newest first, bounded by fromVersion and limit.',
        items: Schema.object(
          required: ['version', 'changes', 'breaking'],
          properties: {
            'version': Schema.string(description: 'The version this entry documents.'),
            'date': Schema.string(
              description: 'ISO 8601 date parsed from the changelog heading. Omitted when absent.',
            ),
            'changes': Schema.string(description: 'The raw changelog text for this version.'),
            'breaking': Schema.bool(
              description: 'Whether this entry was detected as containing a breaking change.',
            ),
          },
        ),
      ),
    },
  ),
);

// ─── browse_api_symbols ───────────────────────────────────────────────────────

/// The `browse_api_symbols` [Tool] definition registered with the MCP server.
final browseApiSymbolsTool = Tool(
  name: 'browse_api_symbols',
  title: 'Browse API symbols',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Use this only when you do not yet know the symbol name and want to narrow by symbol kind. '
      'When the name is already known, call `get_symbol_documentation` directly. '
      'Search for one symbol name at a time — multi-term queries like "PromptsSupport addPrompt" will not match. '
      'Use kind to narrow results when you know the symbol kind (class, method, enum, etc.). '
      'Prefer find_symbols instead for fuzzy, multi-token discovery across names and descriptions — '
      'it shares the same dartdoc index, so switching costs no extra fetch, but find_symbols has no kind filter. '
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
      'kind': Schema.string(
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
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'symbols'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'symbols': Schema.list(
        description: 'Matching symbols, name matches ranked before description-only matches.',
        items: Schema.object(
          required: ['name', 'qualifiedName', 'href', 'type'],
          properties: {
            'name': Schema.string(description: "The symbol's short (unqualified) name."),
            'qualifiedName': Schema.string(
              description: 'The fully-qualified name, suitable for get_symbol_documentation.',
            ),
            'href': Schema.string(
              description: 'The dartdoc-relative link for this symbol, not a fetchable source file path.',
            ),
            'type': Schema.string(
              description: 'The dartdoc symbol kind, e.g. "class", "method", "enum".',
            ),
            'desc': Schema.string(
              description: 'A short description excerpt. Omitted when dartdoc has none.',
            ),
          },
        ),
      ),
    },
  ),
);

// ─── find_symbols ─────────────────────────────────────────────────────────────

/// The `find_symbols` [Tool] definition registered with the MCP server.
final findSymbolsTool = Tool(
  name: 'find_symbols',
  title: 'Find API symbols',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
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
      'Call get_package first if you are not certain the package name is correct.',
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
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'symbols'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'hasMore': Schema.bool(
        description: 'Present and true only when more than 20 matches exist beyond the returned list.',
      ),
      'symbols': Schema.list(
        description: 'Matching symbols, name matches ranked before description-only matches, capped at 20.',
        items: Schema.object(
          required: ['name', 'qualifiedName', 'kind', 'library', 'enclosedBy', 'description', 'href'],
          properties: {
            'name': Schema.string(description: "The symbol's short (unqualified) name."),
            'qualifiedName': Schema.string(
              description: 'The fully-qualified name, suitable for get_symbol_documentation.',
            ),
            'kind': Schema.string(
              description: 'The dartdoc symbol kind, e.g. "class", "method", "enum".',
            ),
            'library': Schema.string(description: 'The package: URI of the library this symbol belongs to.'),
            'enclosedBy': _nullableString(
              'The enclosing container name (e.g. a class name) for methods, constructors, and '
              'accessors; null for top-level symbols.',
            ),
            'description': Schema.string(description: "The symbol's dartdoc description, possibly empty."),
            'href': Schema.string(
              description: 'The dartdoc-relative link for this symbol, not a fetchable source file path.',
            ),
          },
        ),
      ),
    },
  ),
);

// ─── get_symbol_documentation ─────────────────────────────────────────────────

/// The `get_symbol_documentation` [Tool] definition registered with the MCP server.
final getSymbolDocumentationTool = Tool(
  name: 'get_symbol_documentation',
  title: 'Get symbol documentation',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this to read the full signature and doc comment for a known symbol. '
      'Pass the short name ("Client") or a qualified name ("Client.send") — the server resolves it automatically. '
      'Use browse_api_symbols first only when the symbol name is unknown. '
      'Use this to understand parameter types, return types, and usage notes for an API symbol. '
      'If the result is AMBIGUOUS_SYMBOL, pick a qualifiedName from error.details.candidates and retry. '
      'If the doc comment does not cover thrown exceptions, call get_throw_statements next. '
      'If you still need broader implementation details or the canonical file and line numbers, '
      'call get_source_slice next.',
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
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'documentation'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'documentation': Schema.string(
        description:
            'The rendered dartdoc page as text: signature and doc comment always, plus an '
            'Implementation section for concrete members dartdoc chooses to render inline.',
      ),
    },
  ),
);

// ─── get_source_slice ─────────────────────────────────────────────────────────

/// The `get_source_slice` [Tool] definition registered with the MCP server.
final getSourceSliceTool = Tool(
  name: 'get_source_slice',
  title: 'Read package source',
  annotations: kReadOnlyOpenWorldAnnotations,
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
      'effectiveLineEnd always reports the true last line of the region, even when truncated, '
      'so you can drill in with a follow-up line-range read. '
      'Derive the file path from the href returned by browse_api_symbols or find_symbols. '
      'On SOURCE_FILE_NOT_FOUND, read the suggestion field — it lists the closest filename matches. '
      'If the suggestion is not sufficient, call list_package_source_files to browse the full file tree. '
      "For a symbol's rendered signature and doc comment instead of raw source, "
      'use get_symbol_documentation.',
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
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'package', 'file', 'mode', 'lineStart', 'effectiveLineEnd', 'truncated', 'content'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'file': Schema.string(description: 'The file path, as given (leading slash stripped).'),
      'mode': UntitledSingleSelectEnumSchema(
        description: 'Which mode produced this response.',
        values: ['line-range', 'symbol'],
      ),
      'symbolName': Schema.string(
        description: 'The resolved symbol name. Present only in symbol-bounded mode.',
      ),
      'lineStart': Schema.int(description: '1-based inclusive first line of the returned region.'),
      'effectiveLineEnd': Schema.int(
        description:
            "The true last line of the region — the symbol's real end line even when "
            'truncated — so callers can drill in with a follow-up line-range request.',
      ),
      'truncated': Schema.bool(
        description: 'Whether content was collapsed to signature + omission comment + closing brace.',
      ),
      'content': Schema.string(description: 'The extracted Dart source.'),
    },
  ),
);

// ─── list_package_source_files ────────────────────────────────────────────────

/// The `list_package_source_files` [Tool] definition registered with the MCP server.
final listPackageSourceFilesTool = Tool(
  name: 'list_package_source_files',
  title: 'List package source files',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this only when get_source_slice returns SOURCE_FILE_NOT_FOUND and the suggestion does not name the right file. '
      'Set directory and fileExtension to narrow the listing before reading individual files. '
      'Select a path from the result and pass it to get_source_slice. '
      'It never returns file contents — pass a chosen path to get_source_slice for that.',
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(description: 'The pub.dev package name.'),
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
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'name', 'files'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'name': _kPackageNameSchema,
      'files': Schema.list(
        description: 'Matching file paths within the package tarball, sorted alphabetically.',
        items: Schema.string(),
      ),
    },
  ),
);

// ─── get_throw_statements ─────────────────────────────────────────────────────

/// The `get_throw_statements` [Tool] definition registered with the MCP server.
final getThrowStatementsTool = Tool(
  name: 'get_throw_statements',
  title: 'Find throw statements',
  annotations: kReadOnlyOpenWorldAnnotations,
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
      'This is a static scan of throw expressions in source — it does not execute the code '
      'or report exceptions actually raised at runtime.',
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
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'throws'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'throws': Schema.list(
        description: 'Every throw or rethrow expression found, in source order.',
        items: Schema.object(
          required: ['file', 'thrown_type', 'context'],
          properties: {
            'file': Schema.string(description: 'The source file the throw was found in.'),
            'class': Schema.string(
              description: 'The enclosing class, mixin, enum, or extension name. Omitted for top-level functions.',
            ),
            'method': Schema.string(
              description: 'The enclosing method name. Omitted for top-level functions or class-wide scans.',
            ),
            'function': Schema.string(
              description: 'The enclosing top-level function name. Omitted for class members.',
            ),
            'thrown_type': Schema.string(
              description: 'The static type of the thrown expression, or "rethrow" for a bare rethrow statement.',
            ),
            'context': Schema.string(
              description: 'A short source snippet (up to 3 lines) surrounding the throw.',
            ),
          },
        ),
      ),
    },
  ),
);

// ─── compare_packages ─────────────────────────────────────────────────────────

/// The `compare_packages` [Tool] definition registered with the MCP server.
final comparePackagesTool = Tool(
  name: 'compare_packages',
  title: 'Compare packages',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this after search_packages when the user is choosing between multiple candidates. '
      'Pass the top 2–5 names from search results directly. '
      'Returns a comparison matrix — one row per field (score, platform support, SDK constraints, '
      'dependency count, maintenance signals such as license, publisher, and days since last update) '
      'mapped to a value per package — for scanning candidates side by side. '
      'Failed packages appear in errors and are excluded from the matrix — do not retry them. '
      'It never compares API surfaces or README content — use get_symbol_documentation/get_api_diff '
      'or the readme resource for that level of detail.',
  inputSchema: ObjectSchema(
    required: ['packages'],
    properties: {
      'packages': Schema.list(
        description: 'Package names to compare (2–5 entries). Obtain them from search_packages.',
        items: Schema.string(description: 'A pub.dev package name.'),
        minItems: 2,
        maxItems: 5,
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['packages', 'errors', 'matrix'],
    properties: {
      'packages': Schema.list(
        description: 'All requested package names, in request order.',
        items: Schema.string(),
      ),
      'errors': Schema.object(
        description:
            'Maps a failed package name to its domain error code. Empty when every package succeeded. '
            'Packages listed here are excluded from matrix.',
        additionalProperties: Schema.string(),
      ),
      'matrix': Schema.object(
        description:
            'Maps each metric field name (e.g. "likes", "sdkConstraints.dart") to a map of package name → '
            'value for that metric. Packages in errors are excluded. Values are heterogeneous '
            '(string, number, boolean, list, or null depending on the field) and are not further typed here.',
        additionalProperties: Schema.object(
          description: 'Per-package values for one metric, keyed by package name.',
          additionalProperties: true,
        ),
      ),
    },
  ),
);

// ─── list_package_versions ────────────────────────────────────────────────────

/// The `list_package_versions` [Tool] definition registered with the MCP server.
final listPackageVersionsTool = Tool(
  name: 'list_package_versions',
  title: 'List package versions',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this to list every published version of a package, split into '
      'stable, prerelease, and retracted buckets — each sorted newest-first. '
      'Each entry carries the version string and its publish date. '
      'Use it to inspect release cadence, find the newest stable or prerelease '
      'version, or spot retracted versions to avoid depending on. '
      'It carries no changelog content or API information — pair it with get_changelog or get_api_diff '
      'for that; get_api_diff requires two concrete version strings, which this tool is the source of.',
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description: 'The exact pub.dev package name. Obtain it from search_packages if unsure.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['package', 'stable', 'prerelease', 'retracted'],
    properties: {
      'package': _kPackageNameSchema,
      'stable': Schema.list(
        description: 'Non-retracted, non-prerelease versions, newest first.',
        items: _kVersionEntrySchema,
      ),
      'prerelease': Schema.list(
        description: 'Non-retracted pre-release versions, newest first.',
        items: _kVersionEntrySchema,
      ),
      'retracted': Schema.list(
        description: 'Retracted versions (stable or pre-release), newest first. '
            'Retraction takes precedence over the prerelease/stable split.',
        items: _kVersionEntrySchema,
      ),
    },
  ),
);

/// One entry in `list_package_versions`'s `stable`/`prerelease`/`retracted`
/// buckets.
final ObjectSchema _kVersionEntrySchema = Schema.object(
  required: ['version'],
  properties: {
    'version': Schema.string(description: 'The version string.'),
    'publishedAt': Schema.string(
      description: 'ISO 8601 publish timestamp. Omitted when pub.dev does not report one.',
    ),
  },
);

// ─── get_api_diff ─────────────────────────────────────────────────────────────

/// The `get_api_diff` [Tool] definition registered with the MCP server.
final getApiDiffTool = Tool(
  name: 'get_api_diff',
  title: 'Diff public API between versions',
  annotations: kReadOnlyOpenWorldAnnotations,
  description:
      'Call this when the user is upgrading (or downgrading) between two known versions and needs '
      'to see what changed in the public API surface. '
      'Returns two sets — added and removed — each bucketed into libraries, classes, methods, and fields. '
      'The diff is purely presence-based (a symbol is in one version but not the other); '
      'it does NOT detect signature changes such as renamed parameters, changed return types, or nullability. '
      'Both fromVersion and toVersion are required — obtain concrete versions from list_package_versions. '
      'On DOCUMENTATION_NOT_FOUND, one version lacks dartdoc output; '
      'fall back to browse_api_symbols per version as the error suggests. '
      'For narrative release notes rather than a symbol-level diff, use get_changelog instead.',
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
  outputSchema: ObjectSchema(
    required: ['package', 'fromVersion', 'toVersion', 'added', 'removed'],
    properties: {
      'package': _kPackageNameSchema,
      'fromVersion': Schema.string(description: 'The baseline version diffed from, as given.'),
      'toVersion': Schema.string(description: 'The target version diffed to, as given.'),
      'added': _kApiDiffBucketsSchema('Symbols present in toVersion but not fromVersion.'),
      'removed': _kApiDiffBucketsSchema('Symbols present in fromVersion but not toVersion.'),
    },
  ),
);

/// The four API-surface buckets shared by `get_api_diff`'s `added` and
/// `removed` sets.
ObjectSchema _kApiDiffBucketsSchema(String description) => ObjectSchema(
  description: description,
  required: ['libraries', 'classes', 'methods', 'fields'],
  properties: {
    'libraries': Schema.list(
      description: 'Added or removed library qualifiedNames, alphabetically sorted.',
      items: Schema.string(),
    ),
    'classes': Schema.list(
      description:
          'Added or removed class, mixin, enum, extension, extension-type, and typedef '
          'qualifiedNames, alphabetically sorted.',
      items: Schema.string(),
    ),
    'methods': Schema.list(
      description: 'Added or removed method, function, and constructor qualifiedNames, alphabetically sorted.',
      items: Schema.string(),
    ),
    'fields': Schema.list(
      description:
          'Added or removed property, accessor, and constant qualifiedNames, alphabetically sorted.',
      items: Schema.string(),
    ),
  },
);
