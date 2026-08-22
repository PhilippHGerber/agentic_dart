/// Handler for the `get_throw_statements` MCP tool.
///
/// Returns every `throw` expression found within a scoped region of a
/// package's source, with the thrown type and 2–3 lines of surrounding
/// source context. Lets agents answer "what can this throw?" without loading
/// entire source files.
///
/// ## Target declaration resolution
///
/// `symbol` accepts:
/// - A class, mixin, enum, or extension name (e.g. `"Client"`) to scan all its members.
/// - A class member (e.g. `"Client.send"`, `"Client.new"`, `"Client.fromJson"`) to scan that member.
/// - A top-level function (e.g. `"jsonDecode"` or qualified `"convert.jsonDecode"`).
///
/// ## Response shape
///
/// A JSON object carrying the resolved version, package name, and a `throws` array,
/// one entry per `throw` expression:
///
/// ```json
/// {
///   "resolvedVersion": "1.2.3",
///   "package": "http",
///   "throws": [
///     {
///       "file": "lib/src/client.dart",
///       "symbol": "Client.send",
///       "thrownType": "ClientException",
///       "context": "if (closed) {\n  throw ClientException(\"closed\");\n}"
///     }
///   ]
/// }
/// ```
///
/// ## Caches
///
/// Source files and their parsed ASTs are resolved through the shared
/// `AstAccess`, which wraps the `sourceFiles` and `ast` `KeyedCache` facades
/// (from `CacheRegistry`). Both facades are shared with `get_source_slice` so
/// a package's tarball is downloaded, and each of its files parsed, at most
/// once across a single agent turn.
///
/// The dartdoc symbol index is resolved through the shared `apiIndex`
/// [KeyedCache] facade, keyed by `(package, resolvedVersion)` — the same
/// facade used by `browse_api_symbols`, `find_symbols`, `get_api_diff`, and
/// `get_symbol_documentation`, and the package resource handler's `api`
/// resource.
///
/// ## Domain errors
///
/// - `PACKAGE_NOT_FOUND`
/// - `SYMBOL_NOT_FOUND` (class absent, member absent from class, or function not found)
/// - `INVALID_ARGUMENT` — `symbol` missing or empty
/// - `AMBIGUOUS_SYMBOL` + `error.details.candidates` — multiple top-level functions match
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import 'sdk_package_guard.dart';
import 'throw_scan.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

// ─── Private types ────────────────────────────────────────────────────────────

/// Result of scanning a single file for a class method.
///
/// - `classFound == false, result == null` → class absent from this file;
///   caller should scan the next file.
/// - `classFound == true, result == null` → class found but method absent;
///   caller should continue scanning for a homonymous type in another file
///   before concluding `SYMBOL_NOT_FOUND`.
/// - `classFound == true, result != null` → class and method found; done.
typedef _MethodScanResult = ({CallToolResult? result, bool classFound});

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `get_throw_statements` MCP tool.
///
/// Source-file loading and AST parsing are resolved through the shared
/// [AstAccess] — pass the same instance used by `GetSourceSliceHandler` so
/// the two handlers share both caches. The dartdoc symbol index is resolved
/// through the shared `apiIndex` facade — pass the same instance used by
/// `browse_api_symbols` and its siblings.
final class GetThrowStatementsHandler {
  /// Creates a [GetThrowStatementsHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [astAccess] resolves
  /// source files and their parsed ASTs — pass the same instance used by
  /// `GetSourceSliceHandler` so the two handlers share both caches.
  GetThrowStatementsHandler({
    required VersionResolver versionResolver,
    required AstAccess astAccess,
    required KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _astAccess = astAccess,
       _apiIndex = apiIndex,
       _log = log;

  final VersionResolver _versionResolver;
  final AstAccess _astAccess;
  final KeyedCache<ApiIndexId, List<DartdocSymbol>> _apiIndex;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_throw_statements`.
  ///
  /// Returns [CallToolResult.isError] `true` with a structured JSON payload on
  /// any domain failure. On success, content is a JSON array of throw records.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final rawSymbol = args['symbol'] as String?;
    final legacyClass = args['class'] as String?;
    final legacyMethod = args['method'] as String?;
    final version = args['version'] as String?;

    // Determine the symbol, allowing legacy class/method as fallback.
    final String? symbol;
    if (rawSymbol != null && rawSymbol.isNotEmpty) {
      symbol = rawSymbol;
    } else if (legacyClass != null && legacyClass.isNotEmpty) {
      if (legacyMethod != null && legacyMethod.isNotEmpty) {
        symbol = '$legacyClass.$legacyMethod';
      } else {
        symbol = legacyClass;
      }
    } else if (legacyMethod != null && legacyMethod.isNotEmpty) {
      symbol = legacyMethod;
    } else {
      symbol = null;
    }

    // Checked before anything else — including an explicit `version` — so an
    // SDK package name (e.g. "flutter") never reaches VersionResolver/PubDevClient.
    if (sdkPackageGuardError(package) case final error?) return ToolResponse.error(error);

    _log(
      LoggingLevel.info,
      'get_throw_statements: package=$package symbol=$symbol',
    );

    // Validate: `symbol` must be provided.
    if (symbol == null) {
      return ToolResponse.error(_kScopeRequired);
    }

    // Resolve effective version.
    final String resolvedVersion;
    switch (await _versionResolver.resolve(
      package: package,
      supplied: version,
      tool: 'get_throw_statements',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    final dotIndex = symbol.indexOf('.');
    if (dotIndex > 0) {
      final prefix = symbol.substring(0, dotIndex);
      final suffix = symbol.substring(dotIndex + 1);
      if (_isTypeIdentifier(prefix)) {
        return _scanClassMethod(package, resolvedVersion, prefix, suffix, symbol);
      } else {
        return _scanTopLevelFunction(package, resolvedVersion, symbol);
      }
    } else {
      if (_isTypeIdentifier(symbol)) {
        return _scanClass(package, resolvedVersion, symbol);
      } else {
        return _scanTopLevelFunction(package, resolvedVersion, symbol);
      }
    }
  }

  static bool _isTypeIdentifier(String name) {
    final clean = name.startsWith('_') ? name.substring(1) : name;
    if (clean.isEmpty) return false;
    final first = clean[0];
    return first.toUpperCase() == first && first.toLowerCase() != first;
  }

  // ─── Class member scan ───────────────────────────────────────────────────────

  Future<CallToolResult> _scanClassMethod(
    String package,
    String resolvedVersion,
    String className,
    String memberName,
    String fullSymbol,
  ) async {
    final Map<String, String> files;
    switch (await _astAccess.sourceFiles(package, resolvedVersion)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    var classWasFound = false;
    for (final filePath in sortedDartPaths(files.keys)) {
      final (:result, :classFound) = await _scanClassMethodInFile(
        package,
        resolvedVersion,
        filePath,
        className,
        memberName,
      );
      if (classFound) classWasFound = true;
      if (result != null) return result;
    }

    if (classWasFound) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: 'Method "$memberName" was not found in class "$className".',
          suggestion:
              'Verify the method name is spelled correctly. '
              'Use get_symbol_documentation to inspect all members of this class.',
        ),
      );
    }

    return ToolResponse.error(_classNotFoundError(className));
  }

  // ─── Entire class scan ───────────────────────────────────────────────────────

  Future<CallToolResult> _scanClass(
    String package,
    String resolvedVersion,
    String className,
  ) async {
    final Map<String, String> files;
    switch (await _astAccess.sourceFiles(package, resolvedVersion)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    final aggregated = <Map<String, Object?>>[];
    var classWasFound = false;
    for (final filePath in sortedDartPaths(files.keys)) {
      final partialResults = await _scanEntireClassInFile(
        package,
        resolvedVersion,
        filePath,
        className,
      );
      if (partialResults != null) {
        classWasFound = true;
        aggregated.addAll(partialResults);
      }
    }

    if (classWasFound) {
      return _successJson(package, aggregated, resolvedVersion);
    }

    return ToolResponse.error(_classNotFoundError(className));
  }

  // ─── Class-level helpers ────────────────────────────────────────────────────

  /// Scans [filePath] for [className] and collects throws from all its members.
  Future<List<Map<String, Object?>>?> _scanEntireClassInFile(
    String package,
    String resolvedVersion,
    String filePath,
    String className,
  ) async {
    final ParseStringResult ast;
    switch (await _astAccess.unit(package, resolvedVersion, filePath)) {
      case PubDevFailure(:final error):
        throw StateError('unexpected failure parsing an already-listed source file: $error');
      case PubDevSuccess(:final value):
        ast = value;
    }

    final members = _astAccess.member(ast.unit, className);
    if (members == null) return null;

    final results = <Map<String, Object?>>[];
    for (final member in members) {
      final name = memberName(member);
      if (name == null) continue; // skip FieldDeclaration
      collectThrowsForSymbol(
        member,
        ast.lineInfo,
        ast.content,
        filePath,
        '$className.$name',
        results,
      );
    }
    return results;
  }

  /// Scans [filePath] for [className], then extracts throws from [method].
  Future<_MethodScanResult> _scanClassMethodInFile(
    String package,
    String resolvedVersion,
    String filePath,
    String className,
    String method,
  ) async {
    final ParseStringResult ast;
    switch (await _astAccess.unit(package, resolvedVersion, filePath)) {
      case PubDevFailure(:final error):
        throw StateError('unexpected failure parsing an already-listed source file: $error');
      case PubDevSuccess(:final value):
        ast = value;
    }

    final matches = _astAccess.member(ast.unit, className, memberName: method);
    if (matches == null) return (result: null, classFound: false);
    if (matches.isEmpty) {
      return (result: null, classFound: true);
    }

    final results = <Map<String, Object?>>[];
    for (final member in matches) {
      final name = memberName(member) ?? method;
      collectThrowsForSymbol(
        member,
        ast.lineInfo,
        ast.content,
        filePath,
        '$className.$name',
        results,
      );
    }
    return (result: _successJson(package, results, resolvedVersion), classFound: true);
  }

  // ─── Top-level function resolution ──────────────────────────────────────────

  Future<CallToolResult> _scanTopLevelFunction(
    String package,
    String resolvedVersion,
    String functionName, {
    DomainError? fallbackError,
  }) async {
    // Step 1: resolve the API index to locate the function by qualifiedName suffix.
    final List<DartdocSymbol> symbols;
    switch (await _apiIndex.resolve((name: package, version: resolvedVersion))) {
      case PubDevFailure(:final error):
        if (fallbackError != null) return ToolResponse.error(fallbackError);
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        symbols = value;
    }

    if (symbols.isEmpty) {
      if (fallbackError != null) return ToolResponse.error(fallbackError);
      return ToolResponse.error(_kNoDocumentation);
    }

    // Step 2: filter to functions matching `functionName` by qualifiedName suffix.
    final isQualified = functionName.contains('.');
    final unqualifiedName = isQualified
        ? functionName.substring(functionName.lastIndexOf('.') + 1)
        : functionName;

    final candidates = symbols.where((s) {
      if (s.type != 'function') return false;
      if (isQualified) return s.qualifiedName == functionName;
      final dot = s.qualifiedName.indexOf('.');
      if (dot == -1) return s.qualifiedName == functionName;
      return s.qualifiedName.substring(dot + 1) == functionName;
    }).toList();

    if (candidates.isEmpty) {
      return ToolResponse.error(fallbackError ?? _symbolNotFoundError(functionName, package));
    }

    if (candidates.length > 1) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.ambiguousSymbol,
          message: 'Function "$functionName" is ambiguous — ${candidates.length} candidates found.',
          suggestion:
              'Retry with a fully qualified name from the candidates list '
              '(e.g. pass the qualifiedName directly as the `symbol` value).',
          details: {'candidates': candidates.map((s) => s.qualifiedName).toList()},
        ),
      );
    }

    // Step 3: load source files and locate the function.
    final Map<String, String> files;
    switch (await _astAccess.sourceFiles(package, resolvedVersion)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    final hintPaths = _hrefToSourcePaths(candidates.first.href);
    final orderedPaths = isQualified
        ? hintPaths.where(files.containsKey).toList()
        : [
            ...hintPaths.where(files.containsKey),
            ...files.keys.where(
              (k) => k.endsWith('.dart') && !hintPaths.contains(k),
            ),
          ];

    for (final filePath in orderedPaths) {
      final ParseStringResult ast;
      switch (await _astAccess.unit(package, resolvedVersion, filePath)) {
        case PubDevFailure(:final error):
          throw StateError('unexpected failure parsing an already-listed source file: $error');
        case PubDevSuccess(:final value):
          ast = value;
      }
      final funcDecl = findTopLevelFunction(ast.unit, unqualifiedName);
      if (funcDecl != null) {
        final results = <Map<String, Object?>>[];
        collectThrowsForSymbol(
          funcDecl.functionExpression.body,
          ast.lineInfo,
          ast.content,
          filePath,
          isQualified ? functionName : unqualifiedName,
          results,
        );
        return _successJson(package, results, resolvedVersion);
      }
    }

    return ToolResponse.error(
      DomainError(
        code: DomainErrors.symbolNotFound,
        message: 'Function body for "$functionName" could not be located in the source files.',
        suggestion:
            'The function may be generated, external, or defined in a part file. '
            'Try get_source_slice to read the relevant source file directly.',
      ),
    );
  }

  // ─── Utility helpers ──────────────────────────────────────────────────────

  /// Maps a dartdoc href to candidate source file paths.
  static List<String> _hrefToSourcePaths(String href) {
    final slash = href.indexOf('/');
    if (slash <= 0) return const [];
    final libraryName = href.substring(0, slash);
    return ['lib/$libraryName.dart', 'lib/src/$libraryName.dart'];
  }

  // ─── Static error / result builders ──────────────────────────────────────

  static const _kScopeRequired = DomainError(
    code: DomainErrors.invalidArgument,
    message: 'The `symbol` parameter is required.',
    suggestion:
        'To scan all throws in a class, provide symbol: "ClassName" (e.g. "Client"). '
        'To scan a single class member, provide symbol: "ClassName.memberName" (e.g. "Client.send"). '
        'To scan a top-level function, provide symbol: "functionName" (e.g. "jsonDecode").',
  );

  static const _kNoDocumentation = DomainError(
    code: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

  static DomainError _classNotFoundError(String className) => DomainError(
    code: DomainErrors.symbolNotFound,
    message: 'Class "$className" was not found in the source files of the package.',
    suggestion:
        'Verify the class name is spelled correctly. '
        'Use browse_api_symbols with kind=class to discover class names.',
  );

  static DomainError _symbolNotFoundError(String symbol, String package) => DomainError(
    code: DomainErrors.symbolNotFound,
    message: 'Symbol "$symbol" was not found in "$package".',
    suggestion:
        'Verify the symbol name is spelled correctly. '
        'For a class member use "ClassName.memberName". '
        'Use find_symbols or browse_api_symbols to discover symbol names.',
  );

  static CallToolResult _successJson(
    String package,
    List<Map<String, Object?>> results,
    String resolvedVersion,
  ) => ToolResponse.ok({'package': package, 'throws': results}, resolvedVersion: resolvedVersion);
}
