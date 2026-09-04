/// All ToolDefinitions and server instructions for dart_pubdev_mcp.
///
/// This is the complete LLM-facing prompt surface of the server: the
/// [kServerInstructions] string passed during the MCP handshake, plus the
/// [Tool] + [ObjectSchema] pairs that describe each tool's name, title,
/// description, annotations, parameter descriptions, and the `outputSchema`
/// its `structuredContent` conforms to.
///
/// Edit this file to tune how the server and its tools are presented to LLM
/// agents — no handler logic lives here.
library;

import 'package:dart_mcp/server.dart';

import 'tool_descriptions.dart';

export 'tool_descriptions.dart' show kServerInstructions;

/// Shared behavioural hints for every tool in this server: every tool only
/// reads pub.dev/SDK sources and the local cache (`readOnlyHint: true`) and
/// call out over the network to an "open world" of packages (`openWorldHint:
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

// ─── search_packages ──────────────────────────────────────────────────────────

/// The `search_packages` [Tool] definition registered with the MCP server.
final searchPackagesTool = Tool(
  name: 'search_packages',
  title: 'Search pub.dev packages',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kSearchPackagesDescription,
  inputSchema: ObjectSchema(
    required: ['query'],
    properties: {
      'query': Schema.string(
        description:
            'Keyword or partial package name to search for (e.g. "http", "state management"). '
            'Try different keywords if results are empty or unexpected.',
      ),
      'limit': Schema.int(
        description:
            'Maximum number of results to return (e.g. 5, 10; default 5, max 20). '
            'Increase when collecting candidates for compare_packages.',
        minimum: 1,
        maximum: 20,
      ),
      'page': Schema.int(
        description: '1-indexed result page (e.g. 1, 2; default 1).',
        minimum: 1,
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description:
            'Restrict to packages supporting this SDK (e.g. "dart" or "flutter"). '
            'Set when the target environment is known.',
        values: ['dart', 'flutter'],
      ),
      'sort': UntitledSingleSelectEnumSchema(
        description:
            'Sort order (e.g. "relevance", "updated", "likes", "pubPoints"; default "relevance"). '
            'Use updated to find recently maintained packages; use likes or pubPoints to find '
            'well-established ones, but only with a loose or absent query — non-relevance sorts '
            'rank globally, so a narrow query can return top-ranked but unrelated packages.',
        values: ['relevance', 'likes', 'pubPoints', 'updated'],
        defaultValue: 'relevance',
      ),
      'platform': UntitledSingleSelectEnumSchema(
        description:
            'Restrict to packages supporting this platform (e.g. "android", "ios", "web", "linux", "macos", "windows"). '
            "Set when the user's target platform is known.",
        values: ['android', 'ios', 'web', 'linux', 'macos', 'windows'],
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['packages'],
    properties: {
      'packages': Schema.list(
        description:
            'Matching package summaries sorted by relevance or specified sort criterion.',
        items: Schema.object(
          required: [
            'package',
            'version',
            'description',
            'likes',
            'pubPoints',
            'popularity',
            'verified',
            'sdks',
            'platforms',
            'topics',
            'isFlutterFavorite',
            'daysSinceUpdate',
            'activeMaintenance',
          ],
          properties: {
            'package': Schema.string(description: 'The pub.dev package name.'),
            'version': Schema.string(description: 'Latest published stable version.'),
            'description': Schema.string(description: 'Package description from pubspec.'),
            'likes': Schema.int(description: 'pub.dev like count.'),
            'pubPoints': Schema.int(description: 'pub.dev analysis score (0-160).'),
            'popularity': Schema.int(description: '30-day download count.'),
            'verified': Schema.bool(description: 'Whether published by a verified publisher.'),
            'sdks': Schema.list(description: 'Supported SDKs.', items: Schema.string()),
            'platforms': Schema.list(description: 'Supported platforms.', items: Schema.string()),
            'topics': Schema.list(description: 'Package topics.', items: Schema.string()),
            'isFlutterFavorite': Schema.bool(description: 'Whether package is a Flutter Favorite.'),
            'daysSinceUpdate': Schema.int(description: 'Days since the latest release.'),
            'activeMaintenance': Schema.bool(description: 'Whether updated within the last 180 days.'),
            'publisher': Schema.string(description: 'Publisher domain name if verified.'),
            'license': Schema.string(description: 'Detected SPDX license identifier.'),
          },
        ),
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
  description: kGetPackageDescription,
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description:
            'Exact package name on pub.dev (e.g. "http", "riverpod", "path"). '
            'Obtain it from search_packages; never guess.',
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
      'package',
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
      'archiveUrl',
    ],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'version': Schema.string(
        description: 'The package version described — equals resolvedVersion.',
      ),
      'description': Schema.string(description: "The package's pub.dev listing description."),
      'verified': Schema.bool(description: "Whether the package's publisher domain is verified."),
      'publishedAt': Schema.string(
        description:
            'ISO 8601 publish timestamp of this version. Omitted when pub.dev does not report one.',
      ),
      'activeMaintenance': Schema.bool(
        description:
            'Whether the package has been updated recently enough to count as actively maintained.',
      ),
      'likes': Schema.int(description: 'Pub.dev like count.'),
      'pubPoints': Schema.int(description: 'Pub.dev pub points score (0–160).'),
      'popularity': Schema.int(
        description: '30-day download count used for the pub.dev popularity score.',
      ),
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
      'isFlutterFavorite': Schema.bool(
        description: 'Whether pub.dev has flagged this package a Flutter Favorite.',
      ),
      'dependencies': Schema.object(
        description:
            'Runtime dependencies keyed by package name, with version constraint strings as values.',
        additionalProperties: Schema.string(),
      ),
      'devDependencies': Schema.object(
        description:
            'Development dependencies keyed by package name, with version constraint strings as values.',
        additionalProperties: Schema.string(),
      ),
      'versionsRecent': Schema.list(
        description: 'A short list of recently published version strings, newest first.',
        items: Schema.string(),
      ),
      'publisher': Schema.string(
        description: 'The verified publisher domain. Omitted when unverified.',
      ),
      'license': Schema.string(
        description: 'The first SPDX license identifier reported by pub.dev. Omitted when unknown.',
      ),
      'readmeExcerpt': Schema.string(
        description:
            'A truncated excerpt of the README. Omitted when unavailable. '
            'Read pub://package/{name}@{version}/readme for the full text.',
      ),
      'repository': Schema.string(
        description: 'The source repository URL. Omitted when not declared.',
      ),
      'homepage': Schema.string(
        description: 'The pubspec `homepage` URL. Omitted when not declared.',
      ),
      'issueTracker': Schema.string(
        description: 'The pubspec `issue_tracker` URL. Omitted when not declared.',
      ),
      'documentation': Schema.string(
        description: 'The pubspec `documentation` URL. Omitted when not declared.',
      ),
      'archiveUrl': Schema.string(
        description:
            'Direct download URL of the published .tar.gz for this version — use it '
            '(or `repository`) when the caller needs the package on disk; this server '
            'never writes to the workspace.',
      ),
      'advisories': Schema.object(
        description:
            'Best-effort security-advisory summary, evaluated against resolvedVersion. '
            'Omitted when the advisories fetch fails — that is not itself an error for this tool. '
            'Call get_security_advisories for the full per-advisory detail (summary, aliases, '
            'affected ranges).',
        required: ['count', 'ids', 'affectsResolvedVersion'],
        properties: {
          'count': Schema.int(description: 'Total advisories ever published against the package.'),
          'ids': Schema.list(
            description: 'The primary id of every advisory (e.g. "GHSA-4rgh-jx4f-qfcq").',
            items: Schema.string(),
          ),
          'affectsResolvedVersion': Schema.bool(
            description: "Whether any advisory's OSV affected ranges cover resolvedVersion.",
          ),
        },
      ),
    },
  ),
);

// ─── get_changelog ────────────────────────────────────────────────────────────

/// The `get_changelog` [Tool] definition registered with the MCP server.
final getChangelogTool = Tool(
  name: 'get_changelog',
  title: 'Get structured changelog',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGetChangelogDescription,
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description:
            'Exact package name (e.g. "http", "riverpod", "path"). '
            'Obtain it from search_packages or get_package.',
      ),
      'limit': Schema.int(
        description:
            'Maximum number of entries to return (e.g. 5, 10; default 5). '
            'Increase when fromVersion is many releases behind.',
      ),
      'version': Schema.string(
        description:
            'A specific target or anchor version string (e.g. "1.2.0"). '
            'Omit to anchor to the latest published version.',
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
    required: ['resolvedVersion', 'package', 'entries'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'entries': Schema.list(
        description: 'Changelog entries, newest first, bounded by fromVersion and limit.',
        items: Schema.object(
          required: ['version', 'changes', 'rawText', 'breaking'],
          properties: {
            'version': Schema.string(description: 'The version this entry documents.'),
            'date': Schema.string(
              description: 'ISO 8601 date parsed from the changelog heading. Omitted when absent.',
            ),
            'changes': Schema.list(
              description: 'Parsed list of change bullet/item strings.',
              items: Schema.string(),
            ),
            'rawText': Schema.string(
              description: 'The raw unparsed changelog section text for this version.',
            ),
            'breaking': Schema.bool(
              description: 'Whether this entry was detected as containing a breaking change.',
            ),
          },
        ),
      ),
    },
  ),
);

// ─── get_security_advisories ──────────────────────────────────────────────────

/// The `get_security_advisories` [Tool] definition registered with the MCP server.
final getSecurityAdvisoriesTool = Tool(
  name: 'get_security_advisories',
  title: 'Get security advisories',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGetSecurityAdvisoriesDescription,
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description:
            'Exact package name on pub.dev (e.g. "http", "riverpod", "path"). '
            'Obtain it from search_packages; never guess.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to evaluate advisories against the latest published version.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'package', 'affecting', 'other'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'affecting': Schema.list(
        description: 'Advisories whose OSV affected ranges include the Resolved Version.',
        items: _kSecurityAdvisorySchema,
      ),
      'other': Schema.list(
        description:
            'Advisories published against the package whose OSV affected ranges do not '
            'include the Resolved Version.',
        items: _kSecurityAdvisorySchema,
      ),
    },
  ),
);

/// One advisory entry in `get_security_advisories`'s `affecting`/`other` lists.
final ObjectSchema _kSecurityAdvisorySchema = Schema.object(
  required: ['id', 'aliases', 'summary', 'url', 'affectedRanges'],
  properties: {
    'id': Schema.string(description: 'The advisory\'s primary id (e.g. "GHSA-4rgh-jx4f-qfcq").'),
    'aliases': Schema.list(
      description: 'Alternate ids for the same advisory (e.g. CVE identifiers).',
      items: Schema.string(),
    ),
    'summary': Schema.string(description: 'A short human-readable summary of the vulnerability.'),
    'url': Schema.string(description: "A URL to the advisory's detail page."),
    'affectedRanges': Schema.list(
      description:
          "The advisory's raw OSV affected ranges, unevaluated — inspect these to see why a "
          'version was or was not flagged.',
      items: Schema.object(
        required: ['events'],
        properties: {
          'events': Schema.list(
            description:
                'Ordered OSV range events; each carries whichever of the four fields applies.',
            items: Schema.object(
              properties: {
                'introduced': Schema.string(
                  description:
                      'The version this range becomes affected from, inclusive. '
                      'The literal "0" means affected since the beginning.',
                ),
                'fixed': Schema.string(
                  description:
                      'The version this range stops being affected from, inclusive '
                      '(version >= fixed is unaffected).',
                ),
                'lastAffected': Schema.string(
                  description:
                      'The last version still affected, inclusive '
                      '(version > lastAffected is unaffected).',
                ),
                'limit': Schema.string(
                  description: 'An exclusive upper bound past which this range no longer applies.',
                ),
              },
            ),
          ),
        },
      ),
    ),
  },
);

// ─── browse_api_symbols ───────────────────────────────────────────────────────

/// The `browse_api_symbols` [Tool] definition registered with the MCP server.
final browseApiSymbolsTool = Tool(
  name: 'browse_api_symbols',
  title: 'Browse API symbols',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kBrowseApiSymbolsDescription,
  inputSchema: ObjectSchema(
    required: ['package', 'query'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
      ),
      'query': Schema.string(
        description:
            'A single symbol name or keyword to search for (e.g. "Client", "get", "Response"). '
            'Do not combine a class name with a method name in one query.',
      ),
      'kind': Schema.string(
        description:
            'Filter by dartdoc symbol kind, matched case-insensitively '
            '(e.g. "class", "method", "enum", "function", "typedef"). '
            'Known values: class, mixin, enum, function, constant, method, property, '
            'extension, accessor, constructor, typedef, library. '
            'Omit to return all matching symbol kinds. '
            'Unknown values are accepted without error.',
      ),
      'limit': Schema.int(
        description: 'Maximum number of results to return (e.g. 10, 25; default 10, max 25).',
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
    required: ['resolvedVersion', 'package', 'symbols'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'symbols': Schema.list(
        description: 'Matching symbols, name matches ranked before description-only matches.',
        items: Schema.object(
          required: [
            'name',
            'qualifiedName',
            'kind',
            'library',
            'enclosedBy',
            'description',
            'href',
          ],
          properties: {
            'name': Schema.string(description: "The symbol's short (unqualified) name."),
            'qualifiedName': Schema.string(
              description: 'The fully-qualified name, suitable for get_symbol_documentation.',
            ),
            'kind': Schema.string(
              description: 'The dartdoc symbol kind, e.g. "class", "method", "enum".',
            ),
            'library': Schema.string(
              description: 'The package: URI of the library this symbol belongs to.',
            ),
            'enclosedBy': _nullableString(
              'The enclosing container name (e.g. a class name) for methods, constructors, and '
              'accessors; null for top-level symbols.',
            ),
            'description': Schema.string(
              description: "The symbol's dartdoc description, possibly empty.",
            ),
            'href': Schema.string(
              description:
                  'The dartdoc-relative link for this symbol, not a fetchable source file path.',
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
  description: kFindSymbolsDescription,
  inputSchema: ObjectSchema(
    required: ['package', 'query'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
      ),
      'query': Schema.string(
        description:
            'A symbol name or keyword to search for (e.g. "Client", "send", "timeout"). '
            'Matched case-insensitively against symbol names first, then against short descriptions.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'package', 'symbols'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'hasMore': Schema.bool(
        description:
            'Present and true only when more than 20 matches exist beyond the returned list.',
      ),
      'symbols': Schema.list(
        description:
            'Matching symbols, name matches ranked before description-only matches, capped at 20.',
        items: Schema.object(
          required: [
            'name',
            'qualifiedName',
            'kind',
            'library',
            'enclosedBy',
            'description',
            'href',
          ],
          properties: {
            'name': Schema.string(description: "The symbol's short (unqualified) name."),
            'qualifiedName': Schema.string(
              description: 'The fully-qualified name, suitable for get_symbol_documentation.',
            ),
            'kind': Schema.string(
              description: 'The dartdoc symbol kind, e.g. "class", "method", "enum".',
            ),
            'library': Schema.string(
              description: 'The package: URI of the library this symbol belongs to.',
            ),
            'enclosedBy': _nullableString(
              'The enclosing container name (e.g. a class name) for methods, constructors, and '
              'accessors; null for top-level symbols.',
            ),
            'description': Schema.string(
              description: "The symbol's dartdoc description, possibly empty.",
            ),
            'href': Schema.string(
              description:
                  'The dartdoc-relative link for this symbol, not a fetchable source file path.',
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
  description: kGetSymbolDocumentationDescription,
  inputSchema: ObjectSchema(
    required: ['package', 'symbol'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
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
    required: ['resolvedVersion', 'package', 'symbol', 'documentation'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'symbol': Schema.string(
        description: 'The resolved symbol name.',
      ),
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
  description: kGetSourceSliceDescription,
  inputSchema: ObjectSchema(
    required: ['package', 'path'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
      ),
      'path': Schema.string(
        description:
            'File path relative to the package root '
            '(e.g. "lib/http.dart", "lib/src/client.dart"). '
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
            'Line-range mode: 1-based inclusive first line (e.g. 1, 40). '
            'Omit with lineEnd to return the full file.',
      ),
      'lineEnd': Schema.int(
        description: 'Line-range mode: 1-based inclusive last line (e.g. 50, 100).',
      ),
      'symbol': Schema.string(
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
            'when it spans more than this many lines (e.g. 50, 100). Omit for the full symbol body.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: [
      'resolvedVersion',
      'package',
      'path',
      'mode',
      'lineStart',
      'lineEnd',
      'truncated',
      'content',
    ],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'path': Schema.string(description: 'The file path, as given (leading slash stripped).'),
      'mode': UntitledSingleSelectEnumSchema(
        description: 'Which mode produced this response.',
        values: ['line-range', 'symbol'],
      ),
      'symbol': Schema.string(
        description: 'The resolved symbol name. Present only in symbol-bounded mode.',
      ),
      'lineStart': Schema.int(description: '1-based inclusive first line of the returned region.'),
      'lineEnd': Schema.int(
        description:
            "The true last line of the region — the symbol's real end line even when "
            'truncated — so callers can drill in with a follow-up line-range request.',
      ),
      'truncated': Schema.bool(
        description:
            'Whether content was collapsed to signature + omission comment + closing brace.',
      ),
      'content': Schema.string(description: 'The extracted Dart source.'),
    },
  ),
);

// ─── get_sdk_source_slice ─────────────────────────────────────────────────────

/// The `get_sdk_source_slice` [Tool] definition registered with the MCP server.
final getSdkSourceSliceTool = Tool(
  name: 'get_sdk_source_slice',
  title: 'Read Dart or Flutter SDK source',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGetSdkSourceSliceDescription,
  inputSchema: ObjectSchema(
    required: ['sdk', 'path'],
    properties: {
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK to read from (e.g. "dart" or "flutter").',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description:
            'Dart only (sdk: "dart"): the dart: library name (e.g. "core", "async", "io") — '
            "selects the SDK's lib/<library>/ directory. Required for sdk: \"dart\"; omit for "
            'Flutter.',
      ),
      'package': Schema.string(
        description:
            'Flutter only (sdk: "flutter"): the Flutter package name (e.g. "flutter", '
            '"flutter_test", "flutter_driver") — selects the packages/<package>/lib/ '
            'directory. Required for sdk: "flutter"; omit for Dart.',
      ),
      'path': Schema.string(
        description:
            "File path relative to the selected library's or package's lib/ directory "
            '(e.g. "list.dart" for dart:core\'s List implementation, or '
            '"src/widgets/framework.dart" for package:flutter). '
            'Leading slash is stripped automatically. ".." segments are rejected.',
      ),
      'version': Schema.string(
        description:
            'A Dart or Flutter tag or commit SHA (e.g. "3.12.2"), matching sdk. '
            "Omit to auto-detect: the running server's Dart SDK version, or the local "
            "Flutter install's framework version.",
      ),
      'lineStart': Schema.int(
        description:
            'Line-range mode: 1-based inclusive first line (e.g. 1, 40). '
            'Omit with lineEnd to return the full file.',
      ),
      'lineEnd': Schema.int(
        description: 'Line-range mode: 1-based inclusive last line (e.g. 50, 100).',
      ),
      'symbol': Schema.string(
        description:
            'Symbol-bounded mode: the declaration to extract. '
            'A bare name (e.g. "State") matches a top-level declaration; '
            '"ClassName.member" (e.g. "State.setState") matches a class member. '
            'Use "new" for the unnamed constructor; "==" or "operator ==" for operators. '
            'When provided, lineStart/lineEnd are ignored.',
      ),
      'maxLines': Schema.int(
        description:
            'Symbol-bounded mode: truncate the symbol to signature + closing brace '
            'when it spans more than this many lines (e.g. 50, 100). Omit for the full symbol body.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: [
      'resolvedVersion',
      'sdk',
      'path',
      'mode',
      'lineStart',
      'lineEnd',
      'truncated',
      'content',
    ],
    properties: {
      'resolvedVersion': Schema.string(
        description:
            'The exact SDK ref this response describes — the caller-supplied version, or the '
            'auto-detected Dart/Flutter SDK version when version was omitted.',
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK this response describes.',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description: 'The dart: library name, as given. Present only for sdk: "dart".',
      ),
      'package': Schema.string(
        description: 'The Flutter package name, as given. Present only for sdk: "flutter".',
      ),
      'path': Schema.string(
        description:
            "The file path relative to the library's or package's lib/ directory, as given.",
      ),
      'mode': UntitledSingleSelectEnumSchema(
        description: 'Which mode produced this response.',
        values: ['line-range', 'symbol'],
      ),
      'symbol': Schema.string(
        description: 'The resolved symbol name. Present only in symbol-bounded mode.',
      ),
      'lineStart': Schema.int(description: '1-based inclusive first line of the returned region.'),
      'lineEnd': Schema.int(
        description:
            "The true last line of the region — the symbol's real end line even when "
            'truncated — so callers can drill in with a follow-up line-range request.',
      ),
      'truncated': Schema.bool(
        description:
            'Whether content was collapsed to signature + omission comment + closing brace. '
            'Always false in line-range mode.',
      ),
      'content': Schema.string(description: 'The extracted Dart source.'),
    },
  ),
);

// ─── list_sdk_source_files ────────────────────────────────────────────────────

/// The `list_sdk_source_files` [Tool] definition registered with the MCP server.
final listSdkSourceFilesTool = Tool(
  name: 'list_sdk_source_files',
  title: 'List Dart or Flutter SDK source files',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kListSdkSourceFilesDescription,
  inputSchema: ObjectSchema(
    required: ['sdk'],
    properties: {
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK to list files from (e.g. "dart" or "flutter").',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description:
            'Dart only (sdk: "dart"): restrict the listing to this dart: library '
            '(e.g. "core", "async", "io"). Omit to list every file in the SDK.',
      ),
      'package': Schema.string(
        description:
            'Flutter only (sdk: "flutter"): restrict the listing to this Flutter package '
            '(e.g. "flutter", "flutter_test", "flutter_driver"). '
            'Omit to list every file across every Flutter package.',
      ),
      'version': Schema.string(
        description:
            'A Dart or Flutter tag or commit SHA (e.g. "3.12.2"), matching sdk. '
            "Omit to auto-detect: the running server's Dart SDK version, or the local "
            "Flutter install's framework version.",
      ),
      'directory': Schema.string(
        description:
            'Path prefix filter (e.g. "lib/core/"), or a full file path '
            '(e.g. "lib/core/list.dart") to scope to that one file. '
            'Set this to avoid scanning the full tree. '
            'Trailing slash is added automatically if absent from a prefix.',
      ),
      'fileExtension': Schema.string(
        description:
            'Extension filter (e.g. ".dart"). '
            'AND-combined with directory when both are supplied.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'sdk', 'paths'],
    properties: {
      'resolvedVersion': Schema.string(
        description:
            'The exact SDK ref this response describes — the caller-supplied version, or the '
            'auto-detected Dart/Flutter SDK version when version was omitted.',
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK this response describes.',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description: 'The dart: library filter, as given. Present only when supplied.',
      ),
      'package': Schema.string(
        description: 'The Flutter package filter, as given. Present only when supplied.',
      ),
      'paths': Schema.list(
        description:
            'Matching file paths within the SDK source tree, sorted alphabetically, in '
            "installed-style shape (e.g. 'lib/core/list.dart', 'packages/flutter/lib/src/...').",
        items: Schema.string(),
      ),
    },
  ),
);

// ─── list_package_source_files ────────────────────────────────────────────────

/// The `list_package_source_files` [Tool] definition registered with the MCP server.
final listPackageSourceFilesTool = Tool(
  name: 'list_package_source_files',
  title: 'List package source files',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kListPackageSourceFilesDescription,
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description: 'The pub.dev package name (e.g. "http", "riverpod", "path").',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
      'directory': Schema.string(
        description:
            'Path prefix filter (e.g. "lib/src/"), or a full file path '
            '(e.g. "lib/src/client.dart") to scope to that one file. '
            'Set this to avoid scanning the full tree. '
            'Trailing slash is added automatically if absent from a prefix.',
      ),
      'fileExtension': Schema.string(
        description:
            'Extension filter (e.g. ".dart"). '
            'AND-combined with directory when both are supplied.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'package', 'paths'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'paths': Schema.list(
        description: 'Matching file paths within the package tarball, sorted alphabetically.',
        items: Schema.string(),
      ),
    },
  ),
);

// ─── grep_package_source ──────────────────────────────────────────────────────

/// The `grep_package_source` [Tool] definition registered with the MCP server.
final grepPackageSourceTool = Tool(
  name: 'grep_package_source',
  title: 'Search package source',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGrepPackageSourceDescription,
  inputSchema: ObjectSchema(
    required: ['package', 'pattern'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
      ),
      'version': Schema.string(
        description:
            'A specific version string (e.g. "1.2.0"). '
            'Omit to use the latest published version.',
      ),
      'pattern': Schema.string(
        description:
            'The literal substring to search for (default), or a Dart RegExp pattern when '
            'regex is true (e.g. "ClientException", "^void main").',
      ),
      'regex': Schema.bool(
        description:
            'When true, compile pattern as a Dart RegExp instead of matching it as a literal '
            'substring (e.g. true or false, default false) — an LLM-typed pattern like '
            '"isEmpty()" is matched verbatim rather than having its parens reinterpreted '
            'as regex metacharacters.',
      ),
      'caseInsensitive': Schema.bool(
        description: 'Match case-insensitively (e.g. true or false, default false).',
      ),
      'contextLines': Schema.int(
        description:
            'Symmetric number of lines of context to include before/after each match '
            '(e.g. 2, 5; default 0).',
        minimum: 0,
      ),
      'directory': Schema.string(
        description:
            'Path prefix filter (e.g. "lib/src/"), or a full file path '
            '(e.g. "lib/src/client.dart") to scope to that one file — same normalization as '
            'list_package_source_files. Default scope is the whole package tree.',
      ),
      'fileExtension': Schema.string(
        description:
            'Extension filter (e.g. ".dart"). Extensions on the binary denylist '
            '(.png, .jpg, .jpeg, .gif, .ico, .ttf, .otf, .woff, .woff2, .zip, .gz, .so, .dylib, '
            '.dll) are excluded from the scan by default; naming one here explicitly overrides '
            'that exclusion.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'package', 'pattern', 'matches', 'hasMore'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'pattern': Schema.string(description: 'The search pattern, as given.'),
      'matches': Schema.list(
        description: 'Matches sorted by file path then line number, capped at 50 total.',
        items: Schema.object(
          required: ['path', 'line', 'matchedLine', 'contextBefore', 'contextAfter'],
          properties: {
            'path': Schema.string(description: 'The source file path the match was found in.'),
            'line': Schema.int(description: '1-based line number of the match.'),
            'matchedLine': Schema.string(description: 'The full text of the matching line.'),
            'contextBefore': Schema.list(
              description:
                  'Up to contextLines lines immediately preceding the match, in file order. '
                  'Empty when contextLines is 0 or omitted.',
              items: Schema.string(),
            ),
            'contextAfter': Schema.list(
              description:
                  'Up to contextLines lines immediately following the match, in file order. '
                  'Empty when contextLines is 0 or omitted.',
              items: Schema.string(),
            ),
          },
        ),
      ),
      'hasMore': Schema.bool(
        description: 'True when more than 50 matches exist beyond the returned list.',
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
  description: kGetThrowStatementsDescription,
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
      ),
      'symbol': Schema.string(
        description:
            'The target class (e.g. "Client"), class member (e.g. "Client.send"), or '
            'top-level function (e.g. "jsonDecode") to scan. '
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
    required: ['resolvedVersion', 'package', 'throws'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'package': _kPackageNameSchema,
      'throws': Schema.list(
        description: 'Every throw or rethrow expression found, in source order.',
        items: Schema.object(
          required: ['path', 'line', 'symbol', 'thrownType', 'context'],
          properties: {
            'path': Schema.string(description: 'The source file path the throw was found in.'),
            'line': Schema.int(description: '1-based line number of the throw statement.'),
            'symbol': Schema.string(
              description:
                  'The enclosing declaration (e.g. "Client.send" or "jsonDecode").',
            ),
            'thrownType': Schema.string(
              description:
                  'The static type of the thrown expression, or "rethrow" for a bare rethrow statement.',
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

// ─── get_sdk_throw_statements ──────────────────────────────────────────────────

/// The `get_sdk_throw_statements` [Tool] definition registered with the MCP server.
final getSdkThrowStatementsTool = Tool(
  name: 'get_sdk_throw_statements',
  title: 'Find throw statements in Dart or Flutter SDK source',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGetSdkThrowStatementsDescription,
  inputSchema: ObjectSchema(
    required: ['sdk'],
    properties: {
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK to scan (e.g. "dart" or "flutter").',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description:
            'Dart only (sdk: "dart"): the dart: library name (e.g. "core", "async", "io") — '
            'scopes the scan to the SDK\'s lib/<library>/ directory. Required for sdk: "dart"; '
            'omit for Flutter.',
      ),
      'package': Schema.string(
        description:
            'Flutter only (sdk: "flutter"): the Flutter package name (e.g. "flutter", '
            '"flutter_test", "flutter_driver") — scopes the scan to the '
            'packages/<package>/lib/ directory. Required for sdk: "flutter"; omit for Dart.',
      ),
      'symbol': Schema.string(
        description:
            'The target class (e.g. "List"), class member (e.g. "List.add"), or '
            'top-level function (e.g. "identical") to scan. '
            'On AMBIGUOUS_SYMBOL, inspect error.details.candidates (file paths) and retry with '
            'a narrower scope, e.g. via get_sdk_source_slice.',
      ),
      'version': Schema.string(
        description:
            'A Dart or Flutter tag or commit SHA (e.g. "3.12.2"), matching sdk. '
            "Omit to auto-detect: the running server's Dart SDK version, or the local "
            "Flutter install's framework version.",
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'sdk', 'throws'],
    properties: {
      'resolvedVersion': Schema.string(
        description:
            'The exact SDK ref this response describes — the caller-supplied version, or the '
            'auto-detected Dart/Flutter SDK version when version was omitted.',
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK this response describes.',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description: 'The dart: library name, as given. Present only for sdk: "dart".',
      ),
      'package': Schema.string(
        description: 'The Flutter package name, as given. Present only for sdk: "flutter".',
      ),
      'throws': Schema.list(
        description: 'Every throw or rethrow expression found, in source order.',
        items: Schema.object(
          required: ['path', 'line', 'symbol', 'thrownType', 'context'],
          properties: {
            'path': Schema.string(description: 'The source file path the throw was found in.'),
            'line': Schema.int(description: '1-based line number of the throw statement.'),
            'symbol': Schema.string(
              description:
                  'The enclosing declaration (e.g. "List.add" or "identical").',
            ),
            'thrownType': Schema.string(
              description:
                  'The static type of the thrown expression, or "rethrow" for a bare rethrow statement.',
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

// ─── grep_sdk_source ──────────────────────────────────────────────────────────

/// The `grep_sdk_source` [Tool] definition registered with the MCP server.
final grepSdkSourceTool = Tool(
  name: 'grep_sdk_source',
  title: 'Search Dart or Flutter SDK source',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGrepSdkSourceDescription,
  inputSchema: ObjectSchema(
    required: ['sdk', 'pattern'],
    properties: {
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK to scan (e.g. "dart" or "flutter").',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description:
            'Dart only (sdk: "dart"): the dart: library name (e.g. "core", "async", "io") — '
            "scopes the scan to the SDK's lib/<library>/ directory. Omit to scan the whole "
            'Dart SDK tree.',
      ),
      'package': Schema.string(
        description:
            'Flutter only (sdk: "flutter"): the Flutter package name (e.g. "flutter", '
            '"flutter_test", "flutter_driver") — scopes the scan to the '
            'packages/<package>/lib/ directory. Omit to scan the whole flutter/flutter tree.',
      ),
      'version': Schema.string(
        description:
            'A Dart or Flutter tag or commit SHA (e.g. "3.12.2"), matching sdk. '
            "Omit to auto-detect: the running server's Dart SDK version, or the local "
            "Flutter install's framework version.",
      ),
      'pattern': Schema.string(
        description:
            'The literal substring to search for (default), or a Dart RegExp pattern when '
            'regex is true (e.g. "StatefulWidget", "^abstract class").',
      ),
      'regex': Schema.bool(
        description:
            'When true, compile pattern as a Dart RegExp instead of matching it as a literal '
            'substring (e.g. true or false, default false).',
      ),
      'caseInsensitive': Schema.bool(
        description: 'Match case-insensitively (e.g. true or false, default false).',
      ),
      'contextLines': Schema.int(
        description:
            'Symmetric number of lines of context to include before/after each match '
            '(e.g. 2, 5; default 0).',
        minimum: 0,
      ),
      'directory': Schema.string(
        description:
            'Path prefix filter (e.g. "lib/src/rendering/"), or a full file path '
            '(e.g. "lib/src/rendering/box.dart") to scope to that one file — same normalization '
            'as grep_package_source.',
      ),
      'fileExtension': Schema.string(
        description:
            'Extension filter (e.g. ".yaml"). Overrides the default .dart-only scan scope — '
            'an SDK/framework tarball contains large amounts of non-Dart content, so unlike '
            'grep_package_source, only .dart files are scanned by default.',
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'sdk', 'pattern', 'matches', 'hasMore'],
    properties: {
      'resolvedVersion': Schema.string(
        description:
            'The exact SDK ref this response describes — the caller-supplied version, or the '
            'auto-detected Dart/Flutter SDK version when version was omitted.',
      ),
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK this response describes.',
        values: ['dart', 'flutter'],
      ),
      'library': Schema.string(
        description: 'The dart: library filter, as given. Present only when supplied.',
      ),
      'package': Schema.string(
        description: 'The Flutter package filter, as given. Present only when supplied.',
      ),
      'pattern': Schema.string(description: 'The search pattern, as given.'),
      'matches': Schema.list(
        description: 'Matches sorted by file path then line number, capped at 50 total.',
        items: Schema.object(
          required: ['path', 'line', 'matchedLine', 'contextBefore', 'contextAfter'],
          properties: {
            'path': Schema.string(description: 'The source file path the match was found in.'),
            'line': Schema.int(description: '1-based line number of the match.'),
            'matchedLine': Schema.string(description: 'The full text of the matching line.'),
            'contextBefore': Schema.list(
              description:
                  'Up to contextLines lines immediately preceding the match, in file order. '
                  'Empty when contextLines is 0 or omitted.',
              items: Schema.string(),
            ),
            'contextAfter': Schema.list(
              description:
                  'Up to contextLines lines immediately following the match, in file order. '
                  'Empty when contextLines is 0 or omitted.',
              items: Schema.string(),
            ),
          },
        ),
      ),
      'hasMore': Schema.bool(
        description: 'True when more than 50 matches exist beyond the returned list.',
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
  description: kComparePackagesDescription,
  inputSchema: ObjectSchema(
    required: ['packages'],
    properties: {
      'packages': Schema.list(
        description:
            'Package names to compare (e.g. ["http", "dio"], ["bloc", "riverpod", "provider"]; 2–5 entries). '
            'Obtain them from search_packages.',
        items: Schema.string(description: 'A pub.dev package name (e.g. "http", "dio").'),
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
            'Maps each metric field name (e.g. "likes", "sdkConstraints.dart", "advisories") to a map '
            'of package name → value for that metric. Packages in errors are excluded. Values are '
            'heterogeneous (string, number, boolean, list, or null depending on the field) and are not '
            'further typed here. "advisories" (per-package security-advisory count) is best-effort: a '
            'package whose advisories fetch failed is simply absent from the advisories row, not '
            'present with a null — call get_security_advisories for the full per-advisory detail.',
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
  description: kListPackageVersionsDescription,
  inputSchema: ObjectSchema(
    required: ['package'],
    properties: {
      'package': Schema.string(
        description:
            'The exact pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Obtain it from search_packages if unsure.',
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
        description:
            'Retracted versions (stable or pre-release), newest first. '
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
  description: kGetApiDiffDescription,
  inputSchema: ObjectSchema(
    required: ['package', 'fromVersion', 'toVersion'],
    properties: {
      'package': Schema.string(
        description:
            'The pub.dev package name (e.g. "http", "riverpod", "path"). '
            'Verify with get_package if uncertain.',
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
      'includeSignatureChanges': Schema.bool(
        description:
            'Opt in to a structural comparison of one declaration signature across both '
            'versions (e.g. true or false, default false). Requires symbol — there is no '
            'whole-package structural scan, so this stays cheap and targeted. Default false; '
            'the default call downloads no tarballs.',
      ),
      'symbol': Schema.string(
        description:
            'The declaration to compare when includeSignatureChanges is true — a bare name '
            '(e.g. "Client"), a dotted member name (e.g. "Client.send"), or a full qualifiedName '
            '(e.g. "http.Client"). Resolved against the dartdoc index of each version the same way '
            'get_symbol_documentation resolves symbol. Required when '
            'includeSignatureChanges is true; ignored otherwise.',
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
      'signatureChange': _kSignatureChangeSchema,
    },
  ),
);

/// The `signatureChange` result `get_api_diff` adds when
/// `includeSignatureChanges` and `symbol` were both supplied.
final ObjectSchema _kSignatureChangeSchema = ObjectSchema(
  description:
      'Present only when `includeSignatureChanges` was requested. Compares one declaration '
      'AST-reconstructed signature (modifiers, types, names, parameters, and — for classes — '
      'extends/with/implements clauses; the body/implementation is excluded) across both '
      'versions. Present even when unchanged (`changed: false`) — a confirmed-unchanged result '
      'is a useful answer, not something to omit.',
  required: ['qualifiedName', 'changed', 'before', 'after'],
  properties: {
    'qualifiedName': Schema.string(description: 'The resolved symbol qualifiedName.'),
    'changed': Schema.bool(description: 'Whether `before` and `after` differ.'),
    'before': Schema.string(description: 'The declaration rendered signature in fromVersion.'),
    'after': Schema.string(description: 'The declaration rendered signature in toVersion.'),
  },
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
      description:
          'Added or removed method, function, and constructor qualifiedNames, alphabetically sorted.',
      items: Schema.string(),
    ),
    'fields': Schema.list(
      description:
          'Added or removed property, accessor, and constant qualifiedNames, alphabetically sorted.',
      items: Schema.string(),
    ),
  },
);

// ─── get_sdk_release_notes ───────────────────────────────────────────────────

/// The `get_sdk_release_notes` [Tool] definition registered with the MCP server.
final getSdkReleaseNotesTool = Tool(
  name: 'get_sdk_release_notes',
  title: 'Get SDK release notes',
  annotations: kReadOnlyOpenWorldAnnotations,
  description: kGetSdkReleaseNotesDescription,
  inputSchema: ObjectSchema(
    required: ['sdk'],
    properties: {
      'sdk': UntitledSingleSelectEnumSchema(
        description:
            'Target SDK (e.g. "dart" or "flutter"). '
            'Use dart for Dart SDK changes (language, core libraries, dart:* tools); '
            'use flutter for Flutter framework and engine changes.',
        values: ['dart', 'flutter'],
      ),
      'version': Schema.string(
        description:
            'Target SDK version or tag (e.g. "3.4.0", "3.22.0"). '
            'When omitted, anchors to the newest upstream release in the changelog.',
      ),
      'fromVersion': Schema.string(
        description:
            'Return only entries newer than this version (e.g. "3.2.0"). '
            "Set this to the user's current SDK version for upgrade diffs. "
            'When omitted, only the target version is returned (limit 1).',
      ),
      'limit': Schema.int(
        description:
            'Maximum number of release entries to return (e.g. 1, 5; '
            'default 1 when fromVersion is omitted, default 5 when fromVersion is supplied).',
        minimum: 1,
      ),
    },
  ),
  outputSchema: ObjectSchema(
    required: ['resolvedVersion', 'sdk', 'entries'],
    properties: {
      'resolvedVersion': _kResolvedVersionSchema,
      'sdk': UntitledSingleSelectEnumSchema(
        description: 'Which SDK this response describes.',
        values: ['dart', 'flutter'],
      ),
      'entries': Schema.list(
        description: 'Release entries, newest first, bounded by fromVersion and limit.',
        items: Schema.object(
          required: ['version', 'changes', 'sections', 'breaking'],
          properties: {
            'version': Schema.string(description: 'The SDK version this entry documents.'),
            'date': Schema.string(
              description: 'ISO 8601 date parsed from the release heading. Omitted when absent.',
            ),
            'changes': Schema.list(
              description: 'Flat list of changes for this release across all sections.',
              items: Schema.string(),
            ),
            'sections': Schema.object(
              description:
                  'Categorized sections (e.g. Language, Core libraries, Tools, Breaking changes).',
              additionalProperties: Schema.list(items: Schema.string()),
            ),
            'breaking': Schema.bool(
              description: 'Whether this release was detected as containing a breaking change.',
            ),
          },
        ),
      ),
    },
  ),
);
