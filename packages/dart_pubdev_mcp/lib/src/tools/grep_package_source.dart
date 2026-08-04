/// Handler for the `grep_package_source` MCP tool.
///
/// Searches a package's cached source tree for a literal string or (opt-in)
/// regex pattern, returning matched lines with optional symmetric context.
/// Runs entirely against the already-cached `sourceFiles` facade — the same
/// one `get_source_slice`, `get_throw_statements`, and
/// `list_package_source_files` share — so a warm tarball serves this tool with
/// no extra download.
///
/// ## Matching
///
/// Literal by default: `pattern` is matched as a plain substring. When
/// `regex: true`, `pattern` is compiled as a Dart [RegExp] instead; a compile
/// failure surfaces as `INVALID_ARGUMENT` with the compiler's message in
/// `suggestion`. `caseInsensitive` (default `false`) applies to both modes.
///
/// ## Scope
///
/// Default scope is the whole package tree, matching
/// `list_package_source_files`'s own default (no implicit `lib/`-only
/// restriction). `directory` and `fileExtension` filter the candidate file set
/// exactly as `list_package_source_files` does — `directory` matches either as
/// a folder prefix or, via [matchesDirectoryFilter], as an exact full file
/// path (so passing a complete path scopes the scan to that one file instead
/// of silently matching nothing). Files whose extension is on
/// [kBinaryExtensionDenylist] are excluded by default — every tarball entry is
/// decoded as UTF-8 with malformed bytes allowed through, so binary content
/// can produce spurious garbled matches — unless `fileExtension` names one of
/// them explicitly, which overrides the exclusion.
///
/// ## Response shape
///
/// ```json
/// {
///   "resolvedVersion": "1.2.3",
///   "package": "http",
///   "pattern": "isEmpty",
///   "matches": [
///     {
///       "file": "lib/src/client.dart",
///       "line": 42,
///       "matchedLine": "    if (uri.path.isEmpty) {",
///       "contextBefore": [],
///       "contextAfter": []
///     }
///   ],
///   "hasMore": false
/// }
/// ```
///
/// `contextBefore`/`contextAfter` are always present, empty when
/// `contextLines` is `0` or omitted. Matches are sorted by file path, then by
/// line number, and capped at [kMaxMatches] total — no per-file sub-cap, so a
/// single file dominating the results is itself visible rather than hidden.
/// `hasMore` is `true` when more matches exist beyond the cap.
///
/// The whole scan is bounded by [kScanTimeout] wall-clock time, checked
/// between files; on expiry the call returns a `REQUEST_TIMEOUT` Tool Error
/// with no partial results. This is the only ReDoS/pathological-scan guard —
/// no static regex complexity analysis is performed.
///
/// ## Domain errors
///
/// - `PACKAGE_NOT_FOUND`
/// - `INVALID_ARGUMENT` (`package` or `pattern` missing, or `regex: true`
///   with an uncompilable `pattern`)
/// - `REQUEST_TIMEOUT` (scan exceeded [kScanTimeout])
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import 'arg_parsing.dart';
import 'path_filters.dart';
import 'sdk_package_guard.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Maximum number of matches returned in a single response.
const kMaxMatches = 50;

/// Wall-clock budget for a single `grep_package_source` scan, checked between
/// files.
const kScanTimeout = Duration(seconds: 5);

/// File extensions excluded from the default scan scope.
///
/// Every tarball entry is decoded via `utf8.decode(bytes, allowMalformed:
/// true)` regardless of type (`pub_client.dart`), so binary content can
/// produce spurious garbled matches. An explicit `fileExtension` filter naming
/// one of these overrides the exclusion.
const kBinaryExtensionDenylist = {
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.ico',
  '.ttf',
  '.otf',
  '.woff',
  '.woff2',
  '.zip',
  '.gz',
  '.so',
  '.dylib',
  '.dll',
};

/// Handles calls to the `grep_package_source` MCP tool.
final class GrepPackageSourceHandler {
  /// Creates a [GrepPackageSourceHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [sourceFiles] is the
  /// shared [KeyedCache] facade (from `CacheRegistry`) — pass the same
  /// instance used by `GetSourceSliceHandler`, `GetThrowStatementsHandler`,
  /// and `ListPackageSourceFilesHandler` so all readers share the tarball
  /// download.
  const GrepPackageSourceHandler({
    required VersionResolver versionResolver,
    required KeyedCache<SourceFilesId, Map<String, String>> sourceFiles,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _sourceFiles = sourceFiles,
       _log = log;

  final VersionResolver _versionResolver;
  final KeyedCache<SourceFilesId, Map<String, String>> _sourceFiles;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `grep_package_source`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;
    final pattern = args['pattern'] as String?;
    final useRegex = (args['regex'] as bool?) ?? false;
    final caseInsensitive = (args['caseInsensitive'] as bool?) ?? false;
    final contextLines = asInt(args['contextLines']) ?? 0;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;

    if (package.isEmpty) {
      return ToolResponse.error(_kPackageRequired);
    }

    // Checked before touching VersionResolver/PubDevClient — including with an
    // explicit `version` — so an SDK package name (e.g. "flutter") never reaches either.
    if (sdkPackageGuardError(package) case final error?) return ToolResponse.error(error);

    if (pattern == null || pattern.isEmpty) {
      return ToolResponse.error(_kPatternRequired);
    }

    RegExp? compiled;
    if (useRegex) {
      try {
        compiled = RegExp(pattern, caseSensitive: !caseInsensitive);
      } on FormatException catch (e) {
        return ToolResponse.error(
          DomainError(
            code: DomainErrors.invalidArgument,
            message: 'The `pattern` is not a valid regular expression.',
            suggestion: e.message,
          ),
        );
      }
    }

    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'grep_package_source',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    _log(
      LoggingLevel.info,
      'grep_package_source: package=$package version=$resolvedVersion pattern=$pattern '
      'regex=$useRegex',
    );

    final Map<String, String> files;
    switch (await _sourceFiles.resolve((name: package, version: resolvedVersion))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    final paths = _candidatePaths(files.keys, rawDirectory, fileExtension);

    final matches = <Map<String, Object?>>[];
    final stopwatch = Stopwatch()..start();
    for (final path in paths) {
      if (stopwatch.elapsed > kScanTimeout) {
        return ToolResponse.error(_kScanTimeoutError);
      }
      final content = files[path];
      if (content == null) continue;
      _scanFile(
        path: path,
        content: content,
        pattern: pattern,
        compiled: compiled,
        caseInsensitive: caseInsensitive,
        contextLines: contextLines,
        into: matches,
      );
    }

    final hasMore = matches.length > kMaxMatches;
    return ToolResponse.ok({
      'package': package,
      'pattern': pattern,
      'matches': matches.take(kMaxMatches).toList(),
      'hasMore': hasMore,
    }, resolvedVersion: resolvedVersion);
  }

  /// Resolves the candidate file set: [rawDirectory] prefix-filters (same
  /// normalization as `list_package_source_files`), then either
  /// [fileExtension] narrows to a single extension (overriding the binary
  /// denylist) or the denylist excludes binary extensions by default. Sorted
  /// so matches come out in file-path order.
  static List<String> _candidatePaths(
    Iterable<String> allPaths,
    String? rawDirectory,
    String? fileExtension,
  ) {
    var paths = allPaths.toList();

    paths = paths.where((p) => matchesDirectoryFilter(p, rawDirectory)).toList();
    if (fileExtension != null && fileExtension.isNotEmpty) {
      paths = paths.where((p) => p.endsWith(fileExtension)).toList();
    } else {
      paths = paths.where((p) => !kBinaryExtensionDenylist.any(p.endsWith)).toList();
    }

    paths.sort();
    return paths;
  }

  /// Scans [content] line by line, appending a match record to [into] for
  /// every line matching [pattern] (literal) or [compiled] (regex).
  static void _scanFile({
    required String path,
    required String content,
    required String pattern,
    required RegExp? compiled,
    required bool caseInsensitive,
    required int contextLines,
    required List<Map<String, Object?>> into,
  }) {
    final lines = const LineSplitter().convert(content);
    final patternLower = caseInsensitive ? pattern.toLowerCase() : pattern;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isMatch = compiled != null
          ? compiled.hasMatch(line)
          : caseInsensitive
          ? line.toLowerCase().contains(patternLower)
          : line.contains(pattern);
      if (!isMatch) continue;

      final beforeStart = i - contextLines < 0 ? 0 : i - contextLines;
      final afterEndExclusive = i + 1 + contextLines > lines.length
          ? lines.length
          : i + 1 + contextLines;

      into.add({
        'file': path,
        'line': i + 1,
        'matchedLine': line,
        'contextBefore': lines.sublist(beforeStart, i),
        'contextAfter': lines.sublist(i + 1, afterEndExclusive),
      });
    }
  }

  static const _kPackageRequired = DomainError(
    code: DomainErrors.invalidArgument,
    message: 'The `package` argument is required.',
    suggestion: 'Provide a pub.dev package name. Use search_packages to find one.',
    suggestedNextStep: {'tool': 'search_packages'},
  );

  static const _kPatternRequired = DomainError(
    code: DomainErrors.invalidArgument,
    message: 'The `pattern` argument is required.',
    suggestion: 'Provide a literal substring, or a Dart RegExp pattern with regex: true.',
  );

  static const _kScanTimeoutError = DomainError(
    code: DomainErrors.requestTimeout,
    message: 'The scan across the package source tree did not complete within 5 seconds.',
    suggestion:
        'Narrow the search with `directory` or `fileExtension`, or simplify the regex pattern.',
  );
}
