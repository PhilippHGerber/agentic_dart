/// Handler for the `get_sdk_throw_statements` MCP tool.
///
/// Mirrors `get_throw_statements`'s scope semantics (`class`/`method`/both/
/// neither) and response shape for Dart or Flutter SDK source, scanning the
/// selected `library` (Dart) or `package` (Flutter) file by file — the same
/// approach `get_throw_statements`'s `class`-provided path already uses.
///
/// ## Top-level function resolution
///
/// Unlike `get_throw_statements`, the `method`-only (no `class`) path cannot
/// consult a dartdoc `apiIndex` facade — no such symbol index exists for SDK
/// code (see ADR 0006). Instead it scans every file in the selected
/// `library`/`package` directly for a matching top-level function
/// declaration: zero matches → `SYMBOL_NOT_FOUND`; more than one match across
/// files → `AMBIGUOUS_SYMBOL` with `error.details.candidates` listing the
/// file path of each match (not a `qualifiedName`, since none exists here).
///
/// ## Response shape
///
/// ```json
/// {
///   "resolvedVersion": "3.12.2",
///   "sdk": "dart",
///   "library": "core",
///   "throws": [ ... same per-record shape as get_throw_statements ... ]
/// }
/// ```
///
/// `library` is present only for `sdk: 'dart'`; `package` is present only for
/// `sdk: 'flutter'`.
///
/// ## Caches
///
/// Source files and their parsed ASTs are resolved through the shared
/// `AstAccess` wired over `CacheRegistry.sdkSourceFiles`/`sdkAst` — the same
/// instance `get_sdk_source_slice` and `list_sdk_source_files` use.
///
/// ## Domain errors
///
/// - `SDK_VERSION_NOT_FOUND`
/// - `SDK_NOT_DETECTED` (Flutter only)
/// - `SYMBOL_NOT_FOUND` (class absent, method absent from class, or no
///   top-level function match)
/// - `INVALID_ARGUMENT` — neither `class` nor `method` provided, or
///   `sdk`/`library`/`package` malformed
/// - `AMBIGUOUS_SYMBOL` + `error.details.candidates` (file paths) — multiple
///   top-level functions match
library;

import 'dart:io' show Platform;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart' show FunctionDeclaration;
import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../data/domain_error.dart';
import '../data/sdk_client.dart';
import 'throw_scan.dart';
import 'tool_response.dart';

// ─── Private types ────────────────────────────────────────────────────────────

/// Result of scanning a single file for a class method — see
/// `get_throw_statements.dart`'s identically-shaped `_MethodScanResult` for
/// the full contract.
typedef _MethodScanResult = ({CallToolResult? result, bool classFound});

/// A top-level function `decl` located in `filePath`, together with its
/// parsed `ast` — carried alongside so a unique match's throws can be
/// collected without re-parsing or re-locating the declaration.
typedef _FunctionMatch = ({String filePath, ParseStringResult ast, FunctionDeclaration decl});

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `get_sdk_throw_statements` MCP tool.
final class GetSdkThrowStatementsHandler {
  /// Creates a [GetSdkThrowStatementsHandler].
  ///
  /// [astAccess] resolves SDK source files and their parsed ASTs — pass the
  /// same instance `get_sdk_source_slice`/`list_sdk_source_files` use.
  /// [platformVersion] overrides `Platform.version` for testing (Dart version
  /// auto-detection); [flutterEnvironment] overrides `Platform.environment`
  /// for testing (Flutter version auto-detection). Production callers omit
  /// both.
  GetSdkThrowStatementsHandler({
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

  /// Handles a [CallToolRequest] for `get_sdk_throw_statements`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final sdk = (args['sdk'] as String?) ?? '';
    final className = args['class'] as String?;
    final rawMethod = args['method'] as String?;
    // Treat an empty-string method as if it were omitted.
    final method = (rawMethod == null || rawMethod.isEmpty) ? null : rawMethod;
    final suppliedVersion = args['version'] as String?;

    _log(
      LoggingLevel.info,
      'get_sdk_throw_statements: sdk=$sdk class=$className method=$method',
    );

    // Validate: at least one of class or method must be provided.
    if (className == null && method == null) {
      return ToolResponse.error(_kScopeRequired);
    }

    return switch (sdk) {
      'dart' => _handleDart(args, suppliedVersion, className, method),
      'flutter' => _handleFlutter(args, suppliedVersion, className, method),
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
    String? className,
    String? method,
  ) async {
    final rawLibrary = (args['library'] as String?) ?? '';
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

    final ref = suppliedVersion ?? resolveDartSdkRef(platformVersion: _platformVersion);

    return _scan(
      cacheName: 'dart_sdk',
      ref: ref,
      prefix: 'lib/$library/',
      className: className,
      method: method,
      sdk: 'dart',
      library: library,
    );
  }

  Future<CallToolResult> _handleFlutter(
    Map<String, Object?> args,
    String? suppliedVersion,
    String? className,
    String? method,
  ) async {
    final rawPackage = (args['package'] as String?) ?? '';
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

    return _scan(
      cacheName: 'flutter_sdk',
      ref: ref,
      prefix: 'packages/$package/lib/',
      className: className,
      method: method,
      sdk: 'flutter',
      package: package,
    );
  }

  // ─── Scope dispatch ─────────────────────────────────────────────────────────

  Future<CallToolResult> _scan({
    required String cacheName,
    required String ref,
    required String prefix,
    required String? className,
    required String? method,
    required String sdk,
    String? library,
    String? package,
  }) async {
    final Map<String, String> allFiles;
    switch (await _astAccess.sourceFiles(cacheName, ref)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        allFiles = value;
    }

    final scopedPaths = sortedDartPaths(allFiles.keys.where((p) => p.startsWith(prefix)));

    return switch ((className, method)) {
      // Shape 1: class only — all throws in the entire class.
      (final c?, null) => _scanEntireClass(cacheName, ref, scopedPaths, c, sdk, library, package),
      // Shape 2: class + method — throws in one class method.
      (final c?, final m?) => _scanClassMethod(
        cacheName,
        ref,
        scopedPaths,
        c,
        m,
        sdk,
        library,
        package,
      ),
      // Shape 3: method only — throws in one top-level function.
      (null, final m?) => _scanTopLevelFunction(
        cacheName,
        ref,
        scopedPaths,
        m,
        sdk,
        library,
        package,
      ),
      // Already rejected by the validation guard in call(); present so the
      // switch is exhaustive without a null-assertion.
      (null, null) => ToolResponse.error(_kScopeRequired),
    };
  }

  // ─── Shape 1: entire class ─────────────────────────────────────────────────

  Future<CallToolResult> _scanEntireClass(
    String cacheName,
    String ref,
    List<String> filePaths,
    String className,
    String sdk,
    String? library,
    String? package,
  ) async {
    // Aggregate results across ALL files: an SDK library/package may declare
    // a class with the same name in multiple files (e.g. part files).
    // Stopping at the first match would miss throws in later homonymous
    // types.
    final aggregated = <Map<String, Object?>>[];
    var classWasFound = false;
    for (final filePath in filePaths) {
      final partialResults = await _scanEntireClassInFile(cacheName, ref, filePath, className);
      if (partialResults != null) {
        classWasFound = true;
        aggregated.addAll(partialResults);
      }
    }

    return classWasFound
        ? _ok(aggregated, ref, sdk, library, package)
        : ToolResponse.error(_classNotFoundError(className));
  }

  /// Scans [filePath] for [className] and collects throws from all its
  /// members. Returns `null` when [className] is not found in this file.
  Future<List<Map<String, Object?>>?> _scanEntireClassInFile(
    String cacheName,
    String ref,
    String filePath,
    String className,
  ) async {
    final ParseStringResult ast;
    switch (await _astAccess.unit(cacheName, ref, filePath)) {
      case PubDevFailure(:final error):
        // filePath came from the sourceFiles map already loaded for this same
        // (cacheName, ref) above, so unit() cannot fail here.
        throw StateError('unexpected failure parsing an already-listed SDK source file: $error');
      case PubDevSuccess(:final value):
        ast = value;
    }

    final members = _astAccess.member(ast.unit, className);
    if (members == null) return null;

    // Class found — collect throws from every member (field declarations
    // are skipped because memberName returns null for them and they have no
    // stable "method" name to include in the response).
    final results = <Map<String, Object?>>[];
    for (final member in members) {
      final name = memberName(member);
      if (name == null) continue; // skip FieldDeclaration
      collectThrows(member, ast.lineInfo, ast.content, filePath, className, name, null, results);
    }
    return results;
  }

  // ─── Shape 2: one class method ─────────────────────────────────────────────

  Future<CallToolResult> _scanClassMethod(
    String cacheName,
    String ref,
    List<String> filePaths,
    String className,
    String method,
    String sdk,
    String? library,
    String? package,
  ) async {
    // Continue scanning ALL files: an SDK library/package may have two
    // classes with the same name in different files. Stopping at the first
    // match would return SYMBOL_NOT_FOUND from a homonymous class that
    // doesn't have the requested method, ignoring one that does.
    var classWasFound = false;
    for (final filePath in filePaths) {
      final (:result, :classFound) = await _scanClassMethodInFile(
        cacheName,
        ref,
        filePath,
        className,
        method,
        sdk,
        library,
        package,
      );
      if (classFound) classWasFound = true;
      if (result != null) return result;
    }

    return classWasFound
        ? ToolResponse.error(
            DomainError(
              code: DomainErrors.symbolNotFound,
              message: 'Method "$method" was not found in class "$className".',
              suggestion:
                  'Verify the method name is spelled correctly. '
                  'Use get_sdk_source_slice with symbolName to inspect this class.',
            ),
          )
        : ToolResponse.error(_classNotFoundError(className));
  }

  Future<_MethodScanResult> _scanClassMethodInFile(
    String cacheName,
    String ref,
    String filePath,
    String className,
    String method,
    String sdk,
    String? library,
    String? package,
  ) async {
    final ParseStringResult ast;
    switch (await _astAccess.unit(cacheName, ref, filePath)) {
      case PubDevFailure(:final error):
        // filePath came from the sourceFiles map already loaded for this same
        // (cacheName, ref) by the caller, so unit() cannot fail here.
        throw StateError('unexpected failure parsing an already-listed SDK source file: $error');
      case PubDevSuccess(:final value):
        ast = value;
    }

    final matches = _astAccess.member(ast.unit, className, memberName: method);
    if (matches == null) return (result: null, classFound: false);
    if (matches.isEmpty) {
      // Class found but method absent in this file — signal to keep scanning.
      return (result: null, classFound: true);
    }

    // Collect throws from every matching member — an accessor pair (a getter
    // and setter) can share `method`, and both must be scanned.
    final results = <Map<String, Object?>>[];
    for (final member in matches) {
      collectThrows(member, ast.lineInfo, ast.content, filePath, className, method, null, results);
    }
    return (result: _ok(results, ref, sdk, library, package), classFound: true);
  }

  // ─── Shape 3: top-level function ──────────────────────────────────────────

  /// Scans every file in [filePaths] for a top-level function named
  /// [method]. No dartdoc/API-index facade is involved here — this is the
  /// one place this tool deliberately diverges from mirroring
  /// `get_throw_statements`'s internals rather than just its interface (see
  /// ADR 0006).
  Future<CallToolResult> _scanTopLevelFunction(
    String cacheName,
    String ref,
    List<String> filePaths,
    String method,
    String sdk,
    String? library,
    String? package,
  ) async {
    final matches = <_FunctionMatch>[];
    for (final filePath in filePaths) {
      final ParseStringResult ast;
      switch (await _astAccess.unit(cacheName, ref, filePath)) {
        case PubDevFailure(:final error):
          // filePath came from the sourceFiles map already loaded above for
          // this same (cacheName, ref), so unit() cannot fail here.
          throw StateError('unexpected failure parsing an already-listed SDK source file: $error');
        case PubDevSuccess(:final value):
          ast = value;
      }
      final decl = findTopLevelFunction(ast.unit, method);
      if (decl != null) {
        matches.add((filePath: filePath, ast: ast, decl: decl));
      }
    }

    if (matches.isEmpty) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: 'Top-level function "$method" was not found.',
          suggestion:
              'Verify the function name is spelled correctly. '
              'Use list_sdk_source_files to browse available files.',
        ),
      );
    }

    if (matches.length > 1) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.ambiguousSymbol,
          message: 'Function "$method" is ambiguous — ${matches.length} candidates found.',
          suggestion:
              'Multiple files declare a top-level function named "$method". '
              'Inspect error.details.candidates and use get_sdk_source_slice with an '
              'explicit file to read one directly.',
          details: {'candidates': matches.map((m) => m.filePath).toList()},
        ),
      );
    }

    final match = matches.single;

    // Start traversal from the function body, not the FunctionDeclaration —
    // FunctionDeclaration contains a FunctionExpression child, and throw
    // collection stops at FunctionExpression to suppress closures. Starting
    // from the body bypasses that check for the outermost scope.
    final results = <Map<String, Object?>>[];
    collectThrows(
      match.decl.functionExpression.body,
      match.ast.lineInfo,
      match.ast.content,
      match.filePath,
      null,
      null,
      method,
      results,
    );
    return _ok(results, ref, sdk, library, package);
  }

  // ─── Utility helpers ───────────────────────────────────────────────────────

  /// Validates [raw] as a single non-empty path segment: no `/`, no `..`, no
  /// bare `.`. Returns `null` when invalid.
  static String? _normalizeSegment(String raw) {
    if (raw.isEmpty || raw.contains('/') || raw == '..' || raw == '.') return null;
    return raw;
  }

  // ─── Static error / result builders ────────────────────────────────────────

  static const _kScopeRequired = DomainError(
    code: DomainErrors.invalidArgument,
    message: 'Either `class` or `method` must be provided.',
    suggestion:
        'To scan all throws in a class, provide `class`. '
        'To scan a single class method, provide both `class` and `method`. '
        'To scan a top-level function, provide only `method`.',
  );

  static DomainError _classNotFoundError(String className) => DomainError(
    code: DomainErrors.symbolNotFound,
    message: 'Class "$className" was not found in the SDK source files scanned.',
    suggestion:
        'Verify the class name is spelled correctly. '
        'Use list_sdk_source_files to browse available files in this library/package.',
  );

  static CallToolResult _ok(
    List<Map<String, Object?>> results,
    String resolvedVersion,
    String sdk,
    String? library,
    String? package,
  ) => ToolResponse.ok({
    'sdk': sdk,
    'library': ?library,
    'package': ?package,
    'throws': results,
  }, resolvedVersion: resolvedVersion);
}
