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
/// Same pattern as `get_method_body`: the API index is consulted for entries
/// where `type == "function"` and the `qualifiedName` suffix matches `method`.
/// Exactly one match → proceed. Multiple matches → `DomainError(AMBIGUOUS_SYMBOL)`
/// with `error.details.candidates`.
///
/// ## Response shape
///
/// JSON array, one entry per `throw` expression:
///
/// ```json
/// [
///   {
///     "file": "lib/src/foo.dart",
///     "class": "MyClass",
///     "method": "doSomething",
///     "thrown_type": "ArgumentError",
///     "context": "if (id.isEmpty) {\n  throw ArgumentError(...);\n}"
///   }
/// ]
/// ```
///
/// `class` and `method` are omitted for top-level function results; `function`
/// is used instead.
///
/// ## Caches
///
/// Source files: `source:<name>:<version>` — shared with
/// `get_package_source_file` and `get_method_body`.
///
/// API index: `api_index:<package>` — shared with `browse_api_symbols` and
/// `get_symbol_documentation`.
///
/// AST snapshots: `ast:<name>:<version>:<filepath>` — shared with
/// `get_method_body` when the same `astCache` instance is injected into both
/// handlers.
///
/// ## Domain errors
///
/// - `package_not_found`
/// - `SYMBOL_NOT_FOUND` (class absent, or method absent from class)
/// - `INVALID_ARGUMENT` — neither `class` nor `method` provided
/// - `AMBIGUOUS_SYMBOL` + `error.details.candidates` — multiple top-level functions match
library;

import 'dart:convert';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import 'browse_api_symbols.dart';
import 'get_method_body.dart';

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
/// Source-file loading is shared via `sourceFilesCache` with
/// `GetPackageSourceFileHandler` and `GetMethodBodyHandler`. The API index
/// cache `apiIndexCache` is shared with `BrowseApiSymbolsHandler` and
/// `GetSymbolDocumentationHandler`. The AST snapshot cache `astCache` is
/// shared with `GetMethodBodyHandler` when the same instance is injected.
///
/// Pass a `clock` override in tests to control cache TTL expiry without
/// sleeping. Pass an explicit `astCache` to share parsed AST results with
/// another handler.
final class GetThrowStatementsHandler {
  /// Creates a [GetThrowStatementsHandler].
  GetThrowStatementsHandler({
    required PubDevClient client,
    required ResponseCache<Map<String, String>> sourceFilesCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required void Function(LoggingLevel, Object) log,
    ResponseCache<ParseStringResult>? astCache,
    Clock? clock,
  }) : _client = client,
       _sourceFilesCache = sourceFilesCache,
       _apiIndexCache = apiIndexCache,
       _log = log,
       _astCache = astCache ?? ResponseCache(clock: clock ?? DateTime.now);

  final PubDevClient _client;
  final ResponseCache<Map<String, String>> _sourceFilesCache;
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;
  final void Function(LoggingLevel, Object) _log;
  final ResponseCache<ParseStringResult> _astCache;

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

    _log(
      LoggingLevel.info,
      'get_throw_statements: package=$package class=$className method=$method',
    );

    // Validate: at least one of class or method must be provided.
    if (className == null && method == null) {
      return _domainError(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'Either `class` or `method` must be provided.',
          suggestion:
              'To scan all throws in a class, provide `class`. '
              'To scan a single class method, provide both `class` and `method`. '
              'To scan a top-level function, provide only `method`.',
        ),
      );
    }

    // Resolve effective version.
    final String effectiveVersion;
    if (version != null) {
      effectiveVersion = version;
    } else {
      _log(
        LoggingLevel.info,
        'get_throw_statements: resolving latest version for $package',
      );
      final packageResult = await _client.getPackage(package);
      if (packageResult case PubDevFailure(:final error)) return _domainError(error);
      effectiveVersion = (packageResult as PubDevSuccess<PackageDetail>).value.version;
    }

    if (className != null && method == null) {
      // Shape 1: class only — all throws in the entire class.
      return _scanEntireClass(package, effectiveVersion, className);
    }
    if (className != null) {
      // Shape 2: class + method — throws in one class method.
      return _scanClassMethod(package, effectiveVersion, className, method!);
    }
    // Shape 3: method only — throws in one top-level function.
    return _scanTopLevelFunction(package, version, effectiveVersion, method!);
  }

  // ─── Shape 1: entire class ─────────────────────────────────────────────────

  Future<CallToolResult> _scanEntireClass(
    String package,
    String version,
    String className,
  ) async {
    final filesResult = await _loadSourceFiles(package, version);
    if (filesResult case PubDevFailure(:final error)) return _domainError(error);
    final files = (filesResult as PubDevSuccess<Map<String, String>>).value;

    // Aggregate results across ALL files: a package may declare a class with
    // the same name in multiple libraries (e.g. part files, extension-type
    // twins). Stopping at the first match would miss throws in later
    // homonymous types.
    final aggregated = <Map<String, Object?>>[];
    var classWasFound = false;
    for (final filePath in _sortedDartPaths(files.keys)) {
      final content = files[filePath]!;
      final partialResults = await _scanEntireClassInFile(
        package,
        version,
        filePath,
        content,
        className,
      );
      if (partialResults != null) {
        classWasFound = true;
        aggregated.addAll(partialResults);
      }
    }

    return classWasFound ? _successJson(aggregated) : _domainError(_classNotFoundError(className));
  }

  /// Scans [filePath] for [className] and collects throws from all its members.
  ///
  /// Returns `null` when [className] is not found in this file, allowing the
  /// caller to continue scanning other files.
  ///
  /// Returns a (possibly empty) list of throw records when the class is found.
  /// Field declarations are excluded — [_memberName] returns `null` for them
  /// and they have no stable `method` name for the response contract.
  Future<List<Map<String, Object?>>?> _scanEntireClassInFile(
    String package,
    String version,
    String filePath,
    String content,
    String className,
  ) async {
    final ast = await _getOrParseAst(package, version, filePath, content);

    for (final decl in ast.unit.declarations) {
      final members = _membersForDecl(decl, className);
      if (members == null) continue;

      // Class found — collect throws from every member (field declarations
      // are skipped because _memberName returns null for them and they have
      // no stable "method" name to include in the response).
      final results = <Map<String, Object?>>[];
      for (final member in members) {
        final memberName = _memberName(member);
        if (memberName == null) continue; // skip FieldDeclaration
        _collectThrows(
          member,
          ast.lineInfo,
          content,
          filePath,
          className,
          memberName,
          null,
          results,
        );
      }
      return results;
    }
    return null;
  }

  // ─── Shape 2: one class method ─────────────────────────────────────────────

  Future<CallToolResult> _scanClassMethod(
    String package,
    String version,
    String className,
    String method,
  ) async {
    final filesResult = await _loadSourceFiles(package, version);
    if (filesResult case PubDevFailure(:final error)) return _domainError(error);
    final files = (filesResult as PubDevSuccess<Map<String, String>>).value;

    // Continue scanning ALL files: a package may have two classes with the
    // same name in different libraries.  Stopping at the first match would
    // return `SYMBOL_NOT_FOUND` from a homonymous class that doesn't have
    // the requested method, ignoring the second class that does.
    var classWasFound = false;
    for (final filePath in _sortedDartPaths(files.keys)) {
      final content = files[filePath]!;
      final (:result, :classFound) = await _scanClassMethodInFile(
        package,
        version,
        filePath,
        content,
        className,
        method,
      );
      if (classFound) classWasFound = true;
      if (result != null) return result;
    }

    return classWasFound
        ? _domainError(
            DomainError(
              code: DomainErrors.symbolNotFound,
              message: 'Method "$method" was not found in class "$className".',
              suggestion:
                  'Verify the method name is spelled correctly. '
                  'Use get_symbol_documentation to inspect all members of this class.',
            ),
          )
        : _domainError(_classNotFoundError(className));
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
    String version,
    String filePath,
    String content,
    String className,
    String method,
  ) async {
    final ast = await _getOrParseAst(package, version, filePath, content);

    for (final decl in ast.unit.declarations) {
      final members = _membersForDecl(decl, className);
      if (members == null) continue;

      // Class found — collect all matching members for this lookup name.
      final results = <Map<String, Object?>>[];
      var matchedMember = false;
      for (final member in members) {
        if (!_memberNameMatches(member, method)) continue;
        matchedMember = true;
        _collectThrows(
          member,
          ast.lineInfo,
          content,
          filePath,
          className,
          method,
          null,
          results,
        );
      }
      if (matchedMember) {
        return (result: _successJson(results), classFound: true);
      }

      // Class found but method absent in this file — signal to keep scanning.
      return (result: null, classFound: true);
    }
    return (result: null, classFound: false);
  }

  // ─── Shape 3: top-level function ──────────────────────────────────────────

  Future<CallToolResult> _scanTopLevelFunction(
    String package,
    String? rawVersion,
    String effectiveVersion,
    String method,
  ) async {
    // Step 1: load API index to locate the function by qualifiedName suffix.
    final indexCacheKey = rawVersion == null
        ? '$kApiIndexCachePrefix:$package'
        : '$kApiIndexCachePrefix:$package:$rawVersion';

    List<DartdocSymbol> symbols;
    final cachedIndex = _apiIndexCache.get(indexCacheKey);
    if (cachedIndex != null) {
      _log(LoggingLevel.debug, 'get_throw_statements: index cache hit key=$indexCacheKey');
      symbols = await cachedIndex;
    } else {
      _log(LoggingLevel.debug, 'get_throw_statements: index cache miss key=$indexCacheKey');
      _log(LoggingLevel.info, 'get_throw_statements: index HTTP request package=$package');
      final result = await _client.getApiIndex(package, version: effectiveVersion);
      if (result case PubDevFailure(:final error)) {
        return _domainError(error);
      }
      symbols = (result as PubDevSuccess<List<DartdocSymbol>>).value;
      _apiIndexCache.set(indexCacheKey, Future.value(symbols), kApiDocsTtl);
    }

    if (symbols.isEmpty) return _domainError(_kNoDocumentation);

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
      return _domainError(
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
      return _domainError(
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
    final filesResult = await _loadSourceFiles(package, effectiveVersion);
    if (filesResult case PubDevFailure(:final error)) return _domainError(error);
    final files = (filesResult as PubDevSuccess<Map<String, String>>).value;

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
      final content = files[filePath]!;
      final ast = await _getOrParseAst(package, effectiveVersion, filePath, content);
      final funcDecl = _findTopLevelFunction(ast, unqualifiedName);
      if (funcDecl != null) {
        // Start traversal from the function body, not the FunctionDeclaration —
        // FunctionDeclaration contains a FunctionExpression child, and
        // _visitThrows stops at FunctionExpression to suppress closures.
        // Starting from the body bypasses that check for the outermost scope.
        final results = <Map<String, Object?>>[];
        _collectThrows(
          funcDecl.functionExpression.body,
          ast.lineInfo,
          content,
          filePath,
          null,
          null,
          unqualifiedName,
          results,
        );
        return _successJson(results);
      }
    }

    return _domainError(
      DomainError(
        code: DomainErrors.symbolNotFound,
        message: 'Function body for "$method" could not be located in the source files.',
        suggestion:
            'The function may be generated, external, or defined in a part file. '
            'Try get_package_source_file to read the relevant source file directly.',
      ),
    );
  }

  // ─── Source file loading ───────────────────────────────────────────────────

  Future<PubDevResult<Map<String, String>>> _loadSourceFiles(
    String package,
    String version,
  ) async {
    final cacheKey = 'source:$package:$version';
    final cached = _sourceFilesCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_throw_statements: source cache hit key=$cacheKey');
      return PubDevSuccess(await cached);
    }

    _log(LoggingLevel.debug, 'get_throw_statements: source cache miss key=$cacheKey');
    _log(
      LoggingLevel.info,
      'get_throw_statements: HTTP tarball request package=$package',
    );

    final result = await _client.getPackageSourceFiles(package, version);
    if (result case PubDevSuccess(:final value)) {
      _sourceFilesCache.set(cacheKey, Future.value(value), kSourceFileTtl);
      return PubDevSuccess(value);
    }

    final error = (result as PubDevFailure<Map<String, String>>).error;
    return PubDevFailure(
      error.code == DomainErrors.packageNotFound ? _packageNotFoundError(package) : error,
    );
  }

  // ─── AST parsing & caching ─────────────────────────────────────────────────

  /// Returns the parsed AST for [filePath], computing and caching on first call.
  Future<ParseStringResult> _getOrParseAst(
    String package,
    String version,
    String filePath,
    String content,
  ) async {
    final cacheKey = '$kAstSnapshotCachePrefix:$package:$version:$filePath';

    final cached = _astCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_throw_statements: AST cache hit key=$cacheKey');
      return cached;
    }

    _log(LoggingLevel.debug, 'get_throw_statements: parsing $filePath');

    final result = parseString(
      content: content,
      path: filePath,
      throwIfDiagnostics: false,
    );

    _astCache.set(cacheKey, Future.value(result), kAstSnapshotTtl);
    return result;
  }

  // ─── AST traversal helpers ────────────────────────────────────────────────

  /// Returns the class-member list for [decl] if it declares a type named
  /// [className], or `null` when [decl] is not a matching type declaration.
  ///
  /// Handles [ClassDeclaration], [MixinDeclaration], [ExtensionDeclaration],
  /// and [EnumDeclaration].
  static Iterable<ClassMember>? _membersForDecl(
    CompilationUnitMember decl,
    String className,
  ) {
    if (decl is ClassDeclaration) {
      if (decl.namePart.typeName.lexeme != className) return null;
      final body = decl.body;
      return body is BlockClassBody ? body.members : const <ClassMember>[];
    }
    if (decl is MixinDeclaration) {
      if (decl.name.lexeme != className) return null;
      final body = decl.body;
      return body is BlockClassBody ? body.members : const <ClassMember>[];
    }
    if (decl is ExtensionDeclaration) {
      if (decl.name?.lexeme != className) return null;
      final body = decl.body;
      return body is BlockClassBody ? body.members : const <ClassMember>[];
    }
    if (decl is EnumDeclaration) {
      if (decl.namePart.typeName.lexeme != className) return null;
      return decl.body.members;
    }
    return null;
  }

  /// Finds the first top-level function named [name] in [ast].
  static FunctionDeclaration? _findTopLevelFunction(
    ParseStringResult ast,
    String name,
  ) {
    for (final decl in ast.unit.declarations) {
      if (decl is FunctionDeclaration && decl.name.lexeme == name) {
        return decl;
      }
    }
    return null;
  }

  /// Returns the display name of [member], or `null` for field declarations.
  static String? _memberName(ClassMember member) {
    if (member is MethodDeclaration) return member.name.lexeme;
    if (member is ConstructorDeclaration) {
      final name = member.name?.lexeme;
      return name ?? 'new';
    }
    return null;
  }

  /// Returns `true` when [member]'s name matches [method].
  static bool _memberNameMatches(ClassMember member, String method) {
    final normalized = _normalizeMethodName(method);
    if (member is MethodDeclaration) return member.name.lexeme == normalized;
    if (member is ConstructorDeclaration) {
      final name = member.name?.lexeme ?? '';
      return name == normalized;
    }
    return false;
  }

  /// Normalises [method] to the lexeme used in the AST.
  static String _normalizeMethodName(String method) {
    if (method == 'new') return '';
    const prefix = 'operator ';
    if (method.startsWith(prefix)) return method.substring(prefix.length).trim();
    return method;
  }

  // ─── Throw collection ─────────────────────────────────────────────────────

  /// Recursively collects throw and rethrow expressions from [node] into [results].
  ///
  /// [className] and [methodName] tag class-member results.
  /// [functionName] tags top-level-function results.
  ///
  /// `rethrow` statements produce a record with `thrown_type == "rethrow"`.
  static void _collectThrows(
    AstNode node,
    LineInfo lineInfo,
    String source,
    String filePath,
    String? className,
    String? methodName,
    String? functionName,
    List<Map<String, Object?>> results,
  ) {
    _visitThrows(node, (Expression throwLike) {
      final contextNode = _contextNodeFor(throwLike);
      final thrownType = throwLike is ThrowExpression
          ? _thrownType(throwLike.expression)
          : 'rethrow';
      results.add({
        'file': filePath,
        'class': ?className,
        'method': ?methodName,
        'function': ?functionName,
        'thrown_type': thrownType,
        'context': _contextSnippet(contextNode, throwLike, source, lineInfo),
      });
    });
  }

  /// Recursively visits [node] and calls [onThrowLike] for each
  /// [ThrowExpression] or [RethrowExpression].
  ///
  /// Does not recurse into [FunctionExpression] nodes (closures / lambdas) —
  /// throws inside anonymous functions are not direct throws of the enclosing
  /// method scope.
  static void _visitThrows(AstNode node, void Function(Expression) onThrowLike) {
    if (node is ThrowExpression) {
      onThrowLike(node);
      return; // Do not recurse deeper from a throw.
    }
    if (node is RethrowExpression) {
      onThrowLike(node);
      return; // Do not recurse deeper from a rethrow.
    }
    if (node is FunctionExpression) {
      return; // Suppress recursion into anonymous functions.
    }
    for (final entity in node.childEntities) {
      if (entity is AstNode) {
        _visitThrows(entity, onThrowLike);
      }
    }
  }

  // ─── Context node selection ───────────────────────────────────────────────

  /// Returns the nearest enclosing node that provides meaningful context for
  /// [node].
  ///
  /// Walks up the parent chain:
  /// - Returns immediately on control-flow statements (`if`, `switch`, `for`,
  ///   `while`, `do`, `try`) — these give the richest context.
  /// - Tracks the most-recently-seen non-[Block] [Statement] as a fallback.
  /// - Stops at [FunctionBody] / [MethodDeclaration] / [FunctionDeclaration]
  ///   boundaries to avoid leaking context into sibling nodes.
  static AstNode _contextNodeFor(Expression node) {
    AstNode? lastNonBlockStatement;
    var current = node.parent;
    while (current != null) {
      if (current is FunctionBody ||
          current is MethodDeclaration ||
          current is FunctionDeclaration) {
        break;
      }
      if (current is IfStatement ||
          current is SwitchStatement ||
          current is ForStatement ||
          current is WhileStatement ||
          current is DoStatement ||
          current is TryStatement) {
        return current;
      }
      if (current is Statement && current is! Block) {
        lastNonBlockStatement = current;
      }
      current = current.parent;
    }
    return lastNonBlockStatement ?? node;
  }

  /// Extracts up to three lines of source around [throwLike] within [contextNode].
  static String _contextSnippet(
    AstNode contextNode,
    AstNode throwLike,
    String source,
    LineInfo lineInfo,
  ) {
    const maxLines = 3;

    final contextStartLine = lineInfo.getLocation(contextNode.offset).lineNumber - 1;
    final contextEndOffset = contextNode.end > contextNode.offset
        ? contextNode.end - 1
        : contextNode.end;
    final contextEndLine = lineInfo.getLocation(contextEndOffset).lineNumber - 1;
    final throwLine = lineInfo.getLocation(throwLike.offset).lineNumber - 1;

    var startLine = throwLine > contextStartLine ? throwLine - 1 : throwLine;
    if (startLine < contextStartLine) startLine = contextStartLine;

    var endLine = startLine + maxLines - 1;
    if (endLine > contextEndLine) {
      endLine = contextEndLine;
      startLine = endLine - maxLines + 1;
      if (startLine < contextStartLine) startLine = contextStartLine;
    }

    final startOffset = lineInfo.getOffsetOfLine(startLine);
    final endOffset = endLine + 1 < lineInfo.lineCount
        ? lineInfo.getOffsetOfLine(endLine + 1)
        : source.length;
    return source.substring(startOffset, endOffset).trimRight();
  }

  // ─── Thrown type extraction ───────────────────────────────────────────────

  /// Extracts the type name from the thrown [expr].
  ///
  /// Handles:
  /// - [InstanceCreationExpression]: `throw new/const SomeError(...)`
  /// - [MethodInvocation]: `throw SomeError(...)` (no-new syntax) or
  ///   `throw SomeError.named(...)`
  /// - [SimpleIdentifier]: `throw someVariable`
  /// - [PrefixedIdentifier]: `throw SomeError.instance` (prefix is the class)
  /// - [PropertyAccess]: chained property access
  /// - [ParenthesizedExpression]: unwraps once and recurses
  /// - Fallback: first uppercase token in the expression source text
  static String _thrownType(Expression expr) {
    if (expr is InstanceCreationExpression) {
      return expr.constructorName.type.name.lexeme;
    }
    if (expr is MethodInvocation) {
      final target = expr.target;
      if (target == null) {
        // `throw SomeError(...)` — no-new constructor, parsed as method call.
        return expr.methodName.name;
      }
      if (target is SimpleIdentifier) return target.name;
      if (target is PrefixedIdentifier) return target.identifier.name;
      return expr.methodName.name;
    }
    if (expr is SimpleIdentifier) return expr.name;
    if (expr is PrefixedIdentifier) {
      // `throw SomeError.instance` — the class is the prefix.
      return expr.prefix.name;
    }
    if (expr is PropertyAccess) {
      final target = expr.target;
      if (target is SimpleIdentifier) return target.name;
      if (target is PrefixedIdentifier) return target.prefix.name;
    }
    if (expr is ParenthesizedExpression) return _thrownType(expr.expression);
    // Fallback: first uppercase token in the expression source.
    final text = expr.toSource();
    final match = RegExp('[A-Z][A-Za-z0-9_]*').firstMatch(text);
    return match?.group(0) ?? 'Unknown';
  }

  // ─── Utility helpers ──────────────────────────────────────────────────────

  /// Sorts [paths] so `lib/` files are searched before other directories.
  static List<String> _sortedDartPaths(Iterable<String> paths) => [
    ...paths.where((k) => k.endsWith('.dart') && k.startsWith('lib/')),
    ...paths.where((k) => k.endsWith('.dart') && !k.startsWith('lib/')),
  ];

  /// Maps a dartdoc href to candidate source file paths.
  static List<String> _hrefToSourcePaths(String href) {
    final slash = href.indexOf('/');
    if (slash <= 0) return const [];
    final libraryName = href.substring(0, slash);
    return ['lib/$libraryName.dart', 'lib/src/$libraryName.dart'];
  }

  // ─── Static error / result builders ──────────────────────────────────────

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

  static DomainError _packageNotFoundError(String package) => DomainError(
    code: DomainErrors.packageNotFound,
    message: 'Package "$package" not found on pub.dev.',
    suggestion: 'Verify the package name and try again.',
  );

  static CallToolResult _successJson(List<Map<String, Object?>> results) =>
      CallToolResult(content: [TextContent(text: jsonEncode(results))]);

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
