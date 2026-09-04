/// Handler for the `grep_sdk_source` MCP tool.
///
/// Searches Dart or Flutter SDK source for a literal string or (opt-in) regex
/// pattern, mirroring `grep_package_source`'s search semantics against the
/// SDK/framework source tree instead of a pub.dev package. Runs entirely
/// against the already-cached `sourceFiles` facade — the same one
/// `list_sdk_source_files` and `get_sdk_source_slice` share via `AstAccess`
/// over `CacheRegistry.sdkSourceFiles` — so a warm SDK tarball serves this
/// tool with no extra download.
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
/// `sdk: 'dart'`: `library` optionally restricts the scan to that `dart:`
/// library's `lib/$library/` prefix; omitted, the whole SDK tree is scanned.
/// `sdk: 'flutter'`: `package` optionally restricts the scan to that Flutter
/// package's `packages/$package/lib/` prefix; omitted, the whole framework
/// tree is scanned.
///
/// Unlike `grep_package_source`'s binary-extension-denylist-only default,
/// the default scope here is **`.dart` files only** — an SDK/framework
/// tarball (`dart-lang/sdk`, `flutter/flutter`) contains large amounts of
/// non-Dart content (C++ runtime source, build config, docs, vendored code)
/// that a pub.dev package doesn't. `fileExtension` overrides this default to
/// widen (or further narrow) scope, exactly as it overrides the binary
/// denylist in `grep_package_source`. `directory` filters the candidate set
/// on top of that — either a folder prefix or, via [matchesDirectoryFilter],
/// an exact full file path (so passing a complete path scopes the scan to
/// that one file instead of silently matching nothing) — same normalization
/// as `list_package_source_files`/`grep_package_source`.
///
/// ## Response shape
///
/// ```json
/// {
///   "resolvedVersion": "3.35.0",
///   "sdk": "flutter",
///   "package": "flutter",
///   "pattern": "RenderParagraph",
///   "matches": [
///     {
///       "path": "packages/flutter/lib/src/rendering/paragraph.dart",
///       "line": 42,
///       "matchedLine": "class RenderParagraph extends RenderBox {",
///       "contextBefore": [],
///       "contextAfter": []
///     }
///   ],
///   "hasMore": false
/// }
/// ```
///
/// `library` is present only for `sdk: 'dart'`; `package` only for
/// `sdk: 'flutter'` — same convention as `get_sdk_source_slice`/
/// `list_sdk_source_files`. `contextBefore`/`contextAfter` are always
/// present, empty when `contextLines` is `0` or omitted. Matches are sorted
/// by file path, then by line number, and capped at [kMaxMatches] total.
/// `hasMore` is `true` when more matches exist beyond the cap.
///
/// The whole scan is bounded by [kScanTimeout] wall-clock time, checked
/// between files — identical to `grep_package_source`'s budget, kept the
/// same rather than given a larger one so a timeout self-corrects the
/// caller into narrowing via `library`/`package`/`directory`/`fileExtension`.
///
/// ## Domain errors
///
/// - `SDK_VERSION_NOT_FOUND`
/// - `SDK_NOT_DETECTED` (Flutter only: no `FLUTTER_ROOT`/`PATH`-located
///   install and no explicit `version` override)
/// - `INVALID_ARGUMENT` (`sdk` other than `'dart'`/`'flutter'`, `pattern`
///   missing, `library`/`package` containing a path separator, or
///   `regex: true` with an uncompilable `pattern`)
/// - `REQUEST_TIMEOUT` (scan exceeded [kScanTimeout])
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../data/domain_error.dart';
import '../data/sdk_client.dart';
import 'arg_parsing.dart';
import 'grep_package_source.dart' show kMaxMatches, kScanTimeout;
import 'path_filters.dart';
import 'tool_response.dart';

/// File extensions included in the default scan scope — deliberately the
/// inverse of `grep_package_source`'s binary denylist: an SDK/framework
/// tarball is noisy with non-Dart content, so the default narrows to Dart
/// source rather than excluding a handful of binary extensions.
const kDefaultSdkExtension = '.dart';

/// Handles calls to the `grep_sdk_source` MCP tool.
final class GrepSdkSourceHandler {
  /// Creates a [GrepSdkSourceHandler].
  ///
  /// [astAccess] resolves SDK source-file maps — pass the same instance
  /// `get_sdk_source_slice`/`list_sdk_source_files`/`get_sdk_throw_statements`
  /// use (wired over `CacheRegistry.sdkSourceFiles`/`sdkAst`) so a warm SDK
  /// tarball serves every SDK-family tool. [platformVersion] overrides
  /// `Platform.version` for testing (Dart version auto-detection);
  /// [flutterEnvironment] overrides `Platform.environment` for testing
  /// (Flutter version auto-detection). Production callers omit both.
  GrepSdkSourceHandler({
    required AstAccess astAccess,
    required void Function(LoggingLevel, Object) log,
    String Function()? platformVersion,
    Map<String, String>? flutterEnvironment,
  }) : _astAccess = astAccess,
       _log = log,
       _platformVersion = platformVersion ?? (() => Platform.version),
       _flutterEnvironment = flutterEnvironment;

  final AstAccess _astAccess;
  final void Function(LoggingLevel, Object) _log;
  final String Function() _platformVersion;
  final Map<String, String>? _flutterEnvironment;

  /// Handles a [CallToolRequest] for `grep_sdk_source`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final sdk = (args['sdk'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;
    final pattern = args['pattern'] as String?;
    final useRegex = (args['regex'] as bool?) ?? false;
    final caseInsensitive = (args['caseInsensitive'] as bool?) ?? false;
    final contextLines = asInt(args['contextLines']) ?? 0;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;

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

    return await switch (sdk) {
      'dart' => _handleDart(
        args,
        suppliedVersion,
        pattern,
        compiled,
        caseInsensitive,
        contextLines,
        rawDirectory,
        fileExtension,
      ),
      'flutter' => _handleFlutter(
        args,
        suppliedVersion,
        pattern,
        compiled,
        caseInsensitive,
        contextLines,
        rawDirectory,
        fileExtension,
      ),
      _ => ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'sdk must be "dart" or "flutter".',
          suggestion: 'Pass sdk: "dart" or sdk: "flutter".',
        ),
      ),
    };
  }

  Future<CallToolResult> _handleDart(
    Map<String, Object?> args,
    String? suppliedVersion,
    String pattern,
    RegExp? compiled,
    bool caseInsensitive,
    int contextLines,
    String? rawDirectory,
    String? fileExtension,
  ) async {
    final rawLibrary = args['library'] as String?;
    final library = (rawLibrary == null || rawLibrary.isEmpty) ? null : rawLibrary;
    if (library != null && !_isValidSegment(library)) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'The `library` parameter must be a single path segment '
              '(e.g. "core", "async", "io") — no "/" or ".." characters.',
          suggestion:
              'Pass the dart: library name, e.g. "core" for dart:core, '
              'or omit it to scan every file.',
        ),
      );
    }

    final ref = suppliedVersion ?? resolveDartSdkRef(platformVersion: _platformVersion);

    _log(
      LoggingLevel.info,
      'grep_sdk_source: sdk=dart ref=$ref${library != null ? ' library=$library' : ''} '
      'pattern=$pattern regex=${compiled != null}',
    );

    switch (await _astAccess.sourceFiles('dart_sdk', ref)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _scanAndRespond(
          resolvedVersion: ref,
          sdk: 'dart',
          library: library,
          files: value,
          prefix: library == null ? null : 'lib/$library/',
          pattern: pattern,
          compiled: compiled,
          caseInsensitive: caseInsensitive,
          contextLines: contextLines,
          rawDirectory: rawDirectory,
          fileExtension: fileExtension,
        );
    }
  }

  Future<CallToolResult> _handleFlutter(
    Map<String, Object?> args,
    String? suppliedVersion,
    String pattern,
    RegExp? compiled,
    bool caseInsensitive,
    int contextLines,
    String? rawDirectory,
    String? fileExtension,
  ) async {
    final rawPackage = args['package'] as String?;
    final package = (rawPackage == null || rawPackage.isEmpty) ? null : rawPackage;
    if (package != null && !_isValidSegment(package)) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'The `package` parameter must be a single path segment '
              '(e.g. "flutter", "flutter_test") — no "/" or ".." characters.',
          suggestion:
              'Pass the Flutter package name, e.g. "flutter", '
              'or omit it to scan every file.',
        ),
      );
    }

    final String ref;
    if (suppliedVersion != null) {
      ref = suppliedVersion;
    } else {
      final detected = resolveFlutterSdkRef(environment: _flutterEnvironment);
      if (detected == null) {
        return ToolResponse.error(
          const DomainError(
            code: DomainErrors.sdkNotDetected,
            message: 'No local Flutter install was found via FLUTTER_ROOT or PATH.',
            suggestion:
                'If you have shell access, run `flutter --version --machine` and pass its '
                '`frameworkVersion` value as `version`; otherwise ask the user for their '
                'Flutter version. Setting FLUTTER_ROOT or adding flutter to PATH also works '
                "if you control this process's environment.",
            details: {'sdk': 'flutter'},
          ),
        );
      }
      ref = detected;
    }

    _log(
      LoggingLevel.info,
      'grep_sdk_source: sdk=flutter ref=$ref${package != null ? ' package=$package' : ''} '
      'pattern=$pattern regex=${compiled != null}',
    );

    switch (await _astAccess.sourceFiles('flutter_sdk', ref)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _scanAndRespond(
          resolvedVersion: ref,
          sdk: 'flutter',
          package: package,
          files: value,
          prefix: package == null ? null : 'packages/$package/lib/',
          pattern: pattern,
          compiled: compiled,
          caseInsensitive: caseInsensitive,
          contextLines: contextLines,
          rawDirectory: rawDirectory,
          fileExtension: fileExtension,
        );
    }
  }

  CallToolResult _scanAndRespond({
    required String resolvedVersion,
    required String sdk,
    required Map<String, String> files,
    required String pattern,
    required RegExp? compiled,
    required bool caseInsensitive,
    required int contextLines,
    String? library,
    String? package,
    String? prefix,
    String? rawDirectory,
    String? fileExtension,
  }) {
    final paths = _candidatePaths(files.keys, prefix, rawDirectory, fileExtension);

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
      'sdk': sdk,
      'library': ?library,
      'package': ?package,
      'pattern': pattern,
      'matches': matches.take(kMaxMatches).toList(),
      'hasMore': hasMore,
    }, resolvedVersion: resolvedVersion);
  }

  /// Resolves the candidate file set: [prefix] restricts to a single
  /// library/package (mirroring `list_sdk_source_files`), [rawDirectory]
  /// further prefix-filters, then either [fileExtension] narrows to a single
  /// extension (overriding the `.dart`-only default) or the default keeps
  /// only `.dart` files. Sorted so matches come out in file-path order.
  static List<String> _candidatePaths(
    Iterable<String> allPaths,
    String? prefix,
    String? rawDirectory,
    String? fileExtension,
  ) {
    var paths = allPaths.toList();

    if (prefix != null) {
      paths = paths.where((p) => p.startsWith(prefix)).toList();
    }

    paths = paths.where((p) => matchesDirectoryFilter(p, rawDirectory)).toList();

    if (fileExtension != null && fileExtension.isNotEmpty) {
      paths = paths.where((p) => p.endsWith(fileExtension)).toList();
    } else {
      paths = paths.where((p) => p.endsWith(kDefaultSdkExtension)).toList();
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
        'path': path,
        'line': i + 1,
        'matchedLine': line,
        'contextBefore': lines.sublist(beforeStart, i),
        'contextAfter': lines.sublist(i + 1, afterEndExclusive),
      });
    }
  }

  /// Validates [raw] as a single non-empty path segment: no `/`, no `..`, no
  /// bare `.`.
  static bool _isValidSegment(String raw) =>
      raw.isNotEmpty && !raw.contains('/') && raw != '..' && raw != '.';

  static const _kPatternRequired = DomainError(
    code: DomainErrors.invalidArgument,
    message: 'The `pattern` argument is required.',
    suggestion: 'Provide a literal substring, or a Dart RegExp pattern with regex: true.',
  );

  static const _kScanTimeoutError = DomainError(
    code: DomainErrors.requestTimeout,
    message: 'The scan across the SDK source tree did not complete within 5 seconds.',
    suggestion:
        'Narrow the search with `library`/`package`, `directory`, or `fileExtension`, '
        'or simplify the regex pattern.',
  );
}
