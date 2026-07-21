/// Handler for the `get_sdk_source_slice` MCP tool.
///
/// Extracts Dart or Flutter SDK source from a single file in one of two
/// modes, mirroring `get_source_slice` exactly.
///
/// **Line-range mode** (`file`, optional `lineStart`/`lineEnd`): returns the
/// exact requested 1-based inclusive line range with no truncation. When both
/// bounds are omitted the full file is returned verbatim.
///
/// **Symbol-bounded mode** (`file`, `symbolName`, optional `maxLines`): parses
/// the file with the Dart analyzer, locates the named declaration's AST node,
/// and returns its source. When `maxLines` is supplied and the node spans more
/// lines than that, the response is truncated to the signature, opening
/// brace, a `// ... N lines omitted ...` comment, and the closing brace.
/// `symbolName` resolution follows the same rules as `get_source_slice`'s
/// symbol-bounded mode — see `symbol_bounded_slice.dart`.
///
/// ## Path contract
///
/// For `sdk: 'dart'`, `library` selects a `dart:` library (`core`, `async`,
/// `io`, …) and `file` is the path relative to that library's directory —
/// e.g. `library: 'core', file: 'list.dart'` resolves to the SDK's
/// `lib/core/list.dart`.
///
/// For `sdk: 'flutter'`, `package` selects a Flutter package
/// (`flutter`, `flutter_test`, `flutter_driver`, …) and `file` is the path
/// relative to that package's `lib/` directory — e.g. `package: 'flutter',
/// file: 'src/widgets/framework.dart'` resolves to
/// `packages/flutter/lib/src/widgets/framework.dart`.
///
/// ## Response shape
///
/// Every success response is a JSON object:
///
/// ```json
/// {
///   "resolvedVersion": "3.12.2",
///   "sdk": "dart",
///   "library": "core",
///   "file": "list.dart",
///   "mode": "line-range",
///   "lineStart": 1,
///   "effectiveLineEnd": 40,
///   "truncated": false,
///   "content": "..."
/// }
/// ```
///
/// `library` is present only for `sdk: 'dart'`; `package` is present only for
/// `sdk: 'flutter'`.
///
/// ## Caches
///
/// Source files are resolved through the shared `AstAccess` wired over
/// `CacheRegistry.sdkSourceFiles`/`sdkAst` — a distinct store from the
/// pub.dev-package `AstAccess`, so a given SDK tarball is downloaded, at
/// most, once per resolved ref per cache TTL window.
///
/// ## Domain errors
///
/// - `SDK_VERSION_NOT_FOUND`
/// - `SDK_NOT_DETECTED` (Flutter only: no `FLUTTER_ROOT`/`PATH`-located
///   install and no explicit `version` override)
/// - `SOURCE_FILE_NOT_FOUND` (file absent from the SDK source tree)
/// - `SYMBOL_NOT_FOUND` (symbol-bounded mode, declaration not in the file)
/// - `INVALID_ARGUMENT` (`sdk` other than `'dart'`/`'flutter'`,
///   `library`/`package`/`file` missing or containing `..` segments)
library;

import 'dart:io' show Platform;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../data/domain_error.dart';
import '../data/sdk_client.dart';
import 'line_range_slice.dart';
import 'symbol_bounded_slice.dart';
import 'tool_response.dart';

/// Handles calls to the `get_sdk_source_slice` MCP tool.
final class GetSdkSourceSliceHandler {
  /// Creates a [GetSdkSourceSliceHandler].
  ///
  /// [astAccess] resolves SDK source files and their parsed ASTs — pass an
  /// instance built over `CacheRegistry.sdkSourceFiles`/`sdkAst`, distinct
  /// from the one `get_source_slice`/`get_throw_statements` use for pub.dev
  /// packages. [platformVersion] overrides `Platform.version` for testing
  /// (Dart version auto-detection); [flutterEnvironment] overrides
  /// `Platform.environment` for testing (Flutter version auto-detection, in
  /// particular pointing `FLUTTER_ROOT` at a fixture directory). Production
  /// callers omit both.
  GetSdkSourceSliceHandler({
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

  /// Handles a [CallToolRequest] for `get_sdk_source_slice`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final sdk = (args['sdk'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;
    final rawSymbol = args['symbolName'] as String?;
    final symbolName = (rawSymbol == null || rawSymbol.isEmpty) ? null : rawSymbol;
    final lineStart = _asInt(args['lineStart']);
    final lineEnd = _asInt(args['lineEnd']);
    final maxLines = _asInt(args['maxLines']);

    return switch (sdk) {
      'dart' => _handleDart(args, suppliedVersion, symbolName, maxLines, lineStart, lineEnd),
      'flutter' => _handleFlutter(args, suppliedVersion, symbolName, maxLines, lineStart, lineEnd),
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
    String? symbolName,
    int? maxLines,
    int? lineStart,
    int? lineEnd,
  ) async {
    final rawLibrary = (args['library'] as String?) ?? '';
    final rawFile = (args['file'] as String?) ?? '';

    final library = _normalizeSegment(rawLibrary);
    if (library == null) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'The `library` parameter is required and must be a single path segment '
              '(e.g. "core", "async", "io") — no "/" or ".." characters.',
          suggestion: 'Pass the dart: library name, e.g. "core" for dart:core.',
        ),
      );
    }

    final file = _normalizeRelativePath(rawFile);
    if (file == null) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'The `file` parameter is required and must not contain ".." segments.',
          suggestion:
              'Provide a path relative to the library directory (e.g. "list.dart" for dart:core).',
        ),
      );
    }

    final ref = suppliedVersion ?? resolveDartSdkRef(platformVersion: _platformVersion);
    final lookupPath = 'lib/$library/$file';

    _log(
      LoggingLevel.info,
      'get_sdk_source_slice: sdk=dart library=$library file=$file ref=$ref '
      '${symbolName != null ? 'symbol=$symbolName' : 'lines=$lineStart..$lineEnd'}',
    );

    if (symbolName != null) {
      switch (await _astAccess.unit('dart_sdk', ref, lookupPath)) {
        case PubDevFailure(:final error):
          return ToolResponse.error(error);
        case PubDevSuccess(:final value):
          return _symbolBounded(
            resolvedVersion: ref,
            sdk: 'dart',
            library: library,
            file: file,
            ast: value,
            symbolName: symbolName,
            maxLines: maxLines,
          );
      }
    }

    switch (await _astAccess.fileText('dart_sdk', ref, lookupPath)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _lineRange(
          resolvedVersion: ref,
          sdk: 'dart',
          library: library,
          file: file,
          content: value,
          lineStart: lineStart,
          lineEnd: lineEnd,
        );
    }
  }

  Future<CallToolResult> _handleFlutter(
    Map<String, Object?> args,
    String? suppliedVersion,
    String? symbolName,
    int? maxLines,
    int? lineStart,
    int? lineEnd,
  ) async {
    final rawPackage = (args['package'] as String?) ?? '';
    final rawFile = (args['file'] as String?) ?? '';

    final package = _normalizeSegment(rawPackage);
    if (package == null) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'The `package` parameter is required and must be a single path segment '
              '(e.g. "flutter", "flutter_test") — no "/" or ".." characters.',
          suggestion: 'Pass the Flutter package name, e.g. "flutter" for package:flutter.',
        ),
      );
    }

    final file = _normalizeRelativePath(rawFile);
    if (file == null) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'The `file` parameter is required and must not contain ".." segments.',
          suggestion:
              "Provide a path relative to the package's lib/ directory "
              '(e.g. "src/widgets/framework.dart" for package:flutter).',
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
                'Set the FLUTTER_ROOT environment variable, add flutter to PATH, '
                'or pass an explicit version (a flutter/flutter tag or commit SHA).',
            details: {'sdk': 'flutter'},
          ),
        );
      }
      ref = detected;
    }

    final lookupPath = 'packages/$package/lib/$file';

    _log(
      LoggingLevel.info,
      'get_sdk_source_slice: sdk=flutter package=$package file=$file ref=$ref '
      '${symbolName != null ? 'symbol=$symbolName' : 'lines=$lineStart..$lineEnd'}',
    );

    if (symbolName != null) {
      switch (await _astAccess.unit('flutter_sdk', ref, lookupPath)) {
        case PubDevFailure(:final error):
          return ToolResponse.error(error);
        case PubDevSuccess(:final value):
          return _symbolBounded(
            resolvedVersion: ref,
            sdk: 'flutter',
            package: package,
            file: file,
            ast: value,
            symbolName: symbolName,
            maxLines: maxLines,
          );
      }
    }

    switch (await _astAccess.fileText('flutter_sdk', ref, lookupPath)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _lineRange(
          resolvedVersion: ref,
          sdk: 'flutter',
          package: package,
          file: file,
          content: value,
          lineStart: lineStart,
          lineEnd: lineEnd,
        );
    }
  }

  CallToolResult _lineRange({
    required String resolvedVersion,
    required String sdk,
    required String file,
    required String content,
    String? library,
    String? package,
    int? lineStart,
    int? lineEnd,
  }) {
    final slice = sliceLineRange(content, lineStart, lineEnd);
    return ToolResponse.ok({
      'sdk': sdk,
      'library': ?library,
      'package': ?package,
      'file': file,
      'mode': 'line-range',
      'lineStart': slice.lineStart,
      'effectiveLineEnd': slice.effectiveLineEnd,
      'truncated': false,
      'content': slice.content,
    }, resolvedVersion: resolvedVersion);
  }

  CallToolResult _symbolBounded({
    required String resolvedVersion,
    required String sdk,
    required String file,
    required ParseStringResult ast,
    required String symbolName,
    String? library,
    String? package,
    int? maxLines,
  }) {
    final slice = sliceSymbol(_astAccess, ast, symbolName, maxLines: maxLines);
    if (slice == null) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: 'Symbol "$symbolName" was not found in $file.',
          suggestion:
              'Verify the symbol name is spelled correctly. '
              'For a class member use "ClassName.memberName". '
              'Read the file with a line range instead if you need to browse it.',
        ),
      );
    }

    return ToolResponse.ok({
      'sdk': sdk,
      'library': ?library,
      'package': ?package,
      'file': file,
      'mode': 'symbol',
      'symbolName': symbolName,
      'lineStart': slice.lineStart,
      'effectiveLineEnd': slice.effectiveLineEnd,
      'truncated': slice.truncated,
      'content': slice.content,
    }, resolvedVersion: resolvedVersion);
  }

  // ─── Utility helpers ───────────────────────────────────────────────────────

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Validates [raw] as a single non-empty path segment: no `/`, no `..`, no
  /// bare `.`. Returns `null` when invalid.
  static String? _normalizeSegment(String raw) {
    if (raw.isEmpty || raw.contains('/') || raw == '..' || raw == '.') return null;
    return raw;
  }

  /// Validates and normalizes [raw] as a relative path: strips a leading
  /// `/`, rejects `..` or empty segments. Returns `null` when invalid or empty.
  static String? _normalizeRelativePath(String raw) {
    final stripped = raw.startsWith('/') ? raw.substring(1) : raw;
    if (stripped.isEmpty) return null;
    final segments = stripped.split('/');
    if (segments.any((s) => s.isEmpty || s == '..')) return null;
    return segments.join('/');
  }
}
