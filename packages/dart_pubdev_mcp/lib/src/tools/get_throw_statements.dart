/// Handler for the `get_throw_statements` MCP tool.
///
/// Returns every `throw` expression found within a scoped region of a
/// package's source, with the thrown type and 2–3 lines of surrounding
/// source context. Lets agents answer "what can this throw?" without loading
/// entire source files.
///
/// ## Call shapes
///
/// | `class` | `method` | Behaviour |
/// |---------|----------|-----------|
/// | provided | omitted | All `throw` expressions in the entire class |
/// | provided | provided | `throw` expressions in one class method only |
/// | omitted  | provided | `throw` expressions in one top-level function |
/// | omitted  | omitted  | `DomainError(INVALID_ARGUMENT)` — scope required |
///
/// ## Top-level function resolution
///
/// The API index is consulted for entries
/// where `type == "function"` and the `qualifiedName` suffix matches `method`.
/// Exactly one match → proceed. Multiple matches → `DomainError(AMBIGUOUS_SYMBOL)`
/// with `error.details.candidates`.
///
/// ## Response shape
///
/// A JSON object carrying the resolved version and a `throws` array, one entry
/// per `throw` expression:
///
/// ```json
/// {
///   "resolvedVersion": "1.2.3",
///   "throws": [
///     {
///       "file": "lib/src/foo.dart",
///       "class": "MyClass",
///       "method": "doSomething",
///       "thrown_type": "ArgumentError",
///       "context": "if (id.isEmpty) {\n  throw ArgumentError(...);\n}"
///     }
///   ]
/// }
/// ```
///
/// `class` and `method` are omitted for top-level function results; `function`
/// is used instead.
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
/// - `package_not_found`
/// - `SYMBOL_NOT_FOUND` (class absent, or method absent from class)
/// - `INVALID_ARGUMENT` — neither `class` nor `method` provided
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
    final className = args['class'] as String?;
    final rawMethod = args['method'] as String?;
    final version = args['version'] as String?;
    // Treat an empty-string method as if it were omitted.
    final method = (rawMethod == null || rawMethod.isEmpty) ? null : rawMethod;

    // Checked before anything else — including an explicit `version` — so an
    // SDK package name (e.g. "flutter") never reaches VersionResolver/PubDevClient.
    if (sdkPackageGuardError(package) case final error?) return ToolResponse.error(error);

    _log(
      LoggingLevel.info,
      'get_throw_statements: package=$package class=$className method=$method',
    );

    // Validate: at least one of class or method must be provided.
    if (className == null && method == null) {
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

    return switch ((className, method)) {
      // Shape 1: class only — all throws in the entire class.
      (final c?, null) => _scanEntireClass(package, resolvedVersion, c),
      // Shape 2: class + method — throws in one class method.
      (final c?, final m?) => _scanClassMethod(package, resolvedVersion, c, m),
      // Shape 3: method only — throws in one top-level function.
      (null, final m?) => _scanTopLevelFunction(package, resolvedVersion, m),
      // Already rejected by the validation guard above; present so the switch
      // is exhaustive without a null-assertion.
      (null, null) => ToolResponse.error(_kScopeRequired),
    };
  }

  // ─── Shape 1: entire class ─────────────────────────────────────────────────

  Future<CallToolResult> _scanEntireClass(
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

    // Aggregate results across ALL files: a package may declare a class with
    // the same name in multiple libraries (e.g. part files, extension-type
    // twins). Stopping at the first match would miss throws in later
    // homonymous types.
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

    return classWasFound
        ? _successJson(aggregated, resolvedVersion)
        : ToolResponse.error(_classNotFoundError(className));
  }

  /// Scans [filePath] for [className] and collects throws from all its members.
  ///
  /// Returns `null` when [className] is not found in this file, allowing the
  /// caller to continue scanning other files.
  ///
  /// Returns a (possibly empty) list of throw records when the class is found.
  /// Field declarations are excluded — `memberName` returns `null` for them
  /// and they have no stable `method` name for the response contract.
  Future<List<Map<String, Object?>>?> _scanEntireClassInFile(
    String package,
    String resolvedVersion,
    String filePath,
    String className,
  ) async {
    final ParseStringResult ast;
    switch (await _astAccess.unit(package, resolvedVersion, filePath)) {
      case PubDevFailure(:final error):
        // filePath came from the sourceFiles map already loaded for this same
        // (package, resolvedVersion) above, so unit() cannot fail here.
        throw StateError('unexpected failure parsing an already-listed source file: $error');
      case PubDevSuccess(:final value):
        ast = value;
    }

    final members = _astAccess.member(ast.unit, className);
    if (members == null) return null;

    // Class found — collect throws from every member (field declarations
    // are skipped because _memberName returns null for them and they have
    // no stable "method" name to include in the response).
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
    String package,
    String resolvedVersion,
    String className,
    String method,
  ) async {
    final Map<String, String> files;
    switch (await _astAccess.sourceFiles(package, resolvedVersion)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    // Continue scanning ALL files: a package may have two classes with the
    // same name in different libraries.  Stopping at the first match would
    // return `SYMBOL_NOT_FOUND` from a homonymous class that doesn't have
    // the requested method, ignoring the second class that does.
    var classWasFound = false;
    for (final filePath in sortedDartPaths(files.keys)) {
      final (:result, :classFound) = await _scanClassMethodInFile(
        package,
        resolvedVersion,
        filePath,
        className,
        method,
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
                  'Use get_symbol_documentation to inspect all members of this class.',
            ),
          )
        : ToolResponse.error(_classNotFoundError(className));
  }

  /// Scans [filePath] for [className], then extracts throws from [method].
  ///
  /// Returns `(result: null, classFound: false)` when [className] is not in
  /// this file — the caller should continue scanning the next file.
  ///
  /// Returns `(result: null, classFound: true)` when the class is found but
  /// [method] is absent — the caller should keep scanning other files for a
  /// homonymous type that does contain [method] before concluding
  /// `SYMBOL_NOT_FOUND`.
  ///
  /// Returns `(result: nonNull, classFound: true)` on success.
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
        // filePath came from the sourceFiles map already loaded for this same
        // (package, resolvedVersion) by the caller, so unit() cannot fail here.
        throw StateError('unexpected failure parsing an already-listed source file: $error');
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
    return (result: _successJson(results, resolvedVersion), classFound: true);
  }

  // ─── Shape 3: top-level function ──────────────────────────────────────────

  Future<CallToolResult> _scanTopLevelFunction(
    String package,
    String resolvedVersion,
    String method,
  ) async {
    // Step 1: resolve the API index to locate the function by qualifiedName
    // suffix. The identity always carries the resolved (concrete) version so
    // that a "latest" lookup and an explicit version lookup share the same
    // facade entry.
    final List<DartdocSymbol> symbols;
    switch (await _apiIndex.resolve((name: package, version: resolvedVersion))) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        symbols = value;
    }

    if (symbols.isEmpty) return ToolResponse.error(_kNoDocumentation);

    // Step 2: filter to functions matching `method` by qualifiedName suffix.
    //
    // Qualified (e.g. "foo.log"): match the full qualifiedName — exact
    // disambiguation after a prior AMBIGUOUS_SYMBOL response.
    // Unqualified (e.g. "log"): match functions whose qualifiedName suffix
    // (after the first ".") equals `method`.
    final isQualified = method.contains('.');
    final unqualifiedName = isQualified ? method.substring(method.lastIndexOf('.') + 1) : method;

    final candidates = symbols.where((s) {
      if (s.type != 'function') return false;
      if (isQualified) return s.qualifiedName == method;
      final dot = s.qualifiedName.indexOf('.');
      if (dot == -1) return s.qualifiedName == method;
      return s.qualifiedName.substring(dot + 1) == method;
    }).toList();

    if (candidates.isEmpty) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: 'Top-level function "$method" was not found in "$package".',
          suggestion:
              'Verify the function name. '
              'Use browse_api_symbols with type=function to discover function names.',
        ),
      );
    }

    if (candidates.length > 1) {
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.ambiguousSymbol,
          message: 'Function "$method" is ambiguous — ${candidates.length} candidates found.',
          suggestion:
              'Retry with a fully qualified name from the candidates list '
              '(e.g. pass the qualifiedName directly as the `method` value).',
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
          // filePath came from the sourceFiles map already loaded above for
          // this same (package, resolvedVersion), so unit() cannot fail here.
          throw StateError('unexpected failure parsing an already-listed source file: $error');
        case PubDevSuccess(:final value):
          ast = value;
      }
      final funcDecl = findTopLevelFunction(ast.unit, unqualifiedName);
      if (funcDecl != null) {
        // Start traversal from the function body, not the FunctionDeclaration —
        // FunctionDeclaration contains a FunctionExpression child, and throw
        // collection stops at FunctionExpression to suppress closures.
        // Starting from the body bypasses that check for the outermost scope.
        final results = <Map<String, Object?>>[];
        collectThrows(
          funcDecl.functionExpression.body,
          ast.lineInfo,
          ast.content,
          filePath,
          null,
          null,
          unqualifiedName,
          results,
        );
        return _successJson(results, resolvedVersion);
      }
    }

    return ToolResponse.error(
      DomainError(
        code: DomainErrors.symbolNotFound,
        message: 'Function body for "$method" could not be located in the source files.',
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
    message: 'Either `class` or `method` must be provided.',
    suggestion:
        'To scan all throws in a class, provide `class`. '
        'To scan a single class method, provide both `class` and `method`. '
        'To scan a top-level function, provide only `method`.',
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
        'Use browse_api_symbols with type=class to discover class names.',
  );

  static CallToolResult _successJson(
    List<Map<String, Object?>> results,
    String resolvedVersion,
  ) => ToolResponse.ok({'throws': results}, resolvedVersion: resolvedVersion);
}
