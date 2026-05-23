/// Handler for the `get_method_body` MCP tool.
///
/// Returns the complete source text of a single method, constructor, accessor,
/// or top-level function — byte-exact, using AST node offsets.
///
/// ## Call shapes
///
/// | `class` | `method` | Behaviour |
/// |---------|----------|-----------|
/// | provided | provided | Extract named member from the class |
/// | omitted  | provided | Extract top-level function with that name |
/// | either   | omitted  | `DomainError(invalid_input)` |
///
/// ## Method resolution when `class` is provided
///
/// - **Regular method / static method:** match `name == method` in the class body.
/// - **Named constructor:** match `ConstructorDeclaration.name?.lexeme == method`
///   (e.g. `"fromJson"` matches `ClassName.fromJson`).
/// - **Getter and setter with the same name:** both bodies are returned in one
///   response, each prefixed with a `// getter` or `// setter` label.
/// - **Operator:** normalise input — `"=="` and `"operator =="` both resolve to
///   the `operator ==` node.
///
/// ## Top-level function resolution when `class` is omitted
///
/// The API index is consulted for entries where `type == "function"` and the
/// `qualifiedName` suffix (everything after the first `.`) matches `method`.
/// If exactly one entry matches, the source file is derived from the `href`
/// field (e.g. `"http/get.html"` → `lib/http.dart`) and parsed; if that
/// derivation fails the search falls back to scanning all Dart source files.
/// Multiple matches return `DomainError(ambiguous_symbol)` with an
/// `alternatives` array.
///
/// ## Caches
///
/// Source files: `source:<name>:<version>` — shared with `get_package_source_file`.
///
/// API index: `api_index:<package>` — shared with `browse_api_symbols` and
/// `get_symbol_documentation`.
///
/// AST snapshots: `ast:<name>:<version>:<filepath>` with a [kAstSnapshotTtl]
/// TTL, internal to this handler.
///
/// ## Domain errors
///
/// - `package_not_found`
/// - `class_not_found` (class was provided but not in any source file)
/// - `method_not_found` (member absent from class, or top-level function absent)
/// - `ambiguous_symbol` + `alternatives` (multiple top-level functions match)
/// - `invalid_input` (method was omitted)
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import 'browse_api_symbols.dart';

/// Cache-key prefix for AST snapshot entries.
///
/// Full key format: `$kAstSnapshotCachePrefix:<package>:<version>:<filepath>`.
const kAstSnapshotCachePrefix = 'ast';

// ─── Handler ──────────────────────────────────────────────────────────────────

/// Handles calls to the `get_method_body` MCP tool.
///
/// Source-file loading is shared via `sourceFilesCache` with
/// `GetPackageSourceFileHandler`. The API index cache `apiIndexCache` is shared
/// with `BrowseApiSymbolsHandler` and `GetSymbolDocumentationHandler`. The AST
/// snapshot cache is owned internally and keyed as
/// `ast:<package>:<version>:<filepath>`.
///
/// Pass a `clock` override in tests to control cache TTL expiry without
/// sleeping.
final class GetMethodBodyHandler {
  /// Creates a [GetMethodBodyHandler].
  GetMethodBodyHandler({
    required PubDevClient client,
    required ResponseCache<Map<String, String>> sourceFilesCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required void Function(LoggingLevel, Object) log,
    Clock? clock,
  }) : _client = client,
       _sourceFilesCache = sourceFilesCache,
       _apiIndexCache = apiIndexCache,
       _log = log,
       _astCache = ResponseCache(clock: clock ?? DateTime.now);

  final PubDevClient _client;
  final ResponseCache<Map<String, String>> _sourceFilesCache;
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;
  final void Function(LoggingLevel, Object) _log;
  final ResponseCache<ParseStringResult> _astCache;

  /// Handles a [CallToolRequest] for `get_method_body`.
  ///
  /// Returns [CallToolResult.isError] `true` with a structured JSON payload on
  /// any domain failure.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final method = (args['method'] as String?) ?? '';
    final className = args['class'] as String?;
    final version = args['version'] as String?;

    _log(
      LoggingLevel.info,
      'get_method_body: package=$package class=$className method=$method',
    );

    // Validate: method is always required.
    if (method.isEmpty) {
      return _domainError(
        DomainError(
          error: DomainErrors.invalidInput,
          message: 'The `method` parameter is required.',
          suggestion: className != null
              ? 'Provide the method name to extract from class "$className".'
              : 'Provide the method name. '
                  'To extract a class member, also provide the `class` parameter.',
        ),
      );
    }

    // Resolve effective version.
    final String effectiveVersion;
    if (version != null) {
      effectiveVersion = version;
    } else {
      _log(LoggingLevel.info, 'get_method_body: resolving latest version for $package');
      final packageResult = await _client.getPackage(package);
      if (packageResult case PubDevFailure(:final error)) return _domainError(error);
      effectiveVersion = (packageResult as PubDevSuccess<PackageDetail>).value.version;
    }

    return className != null
        ? await _extractClassMember(package, effectiveVersion, className, method)
        : await _extractTopLevelFunction(package, version, effectiveVersion, method);
  }

  // ─── Class member extraction ───────────────────────────────────────────────

  Future<CallToolResult> _extractClassMember(
    String package,
    String version,
    String className,
    String method,
  ) async {
    final filesResult = await _loadSourceFiles(package, version);
    if (filesResult case PubDevFailure(:final error)) return _domainError(error);
    final files = (filesResult as PubDevSuccess<Map<String, String>>).value;

    // Sort so lib/ files are searched before ancillary directories — most
    // public classes are declared in lib/.
    final sortedPaths = [
      ...files.keys.where((k) => k.endsWith('.dart') && k.startsWith('lib/')),
      ...files.keys.where((k) => k.endsWith('.dart') && !k.startsWith('lib/')),
    ];

    for (final filePath in sortedPaths) {
      final content = files[filePath]!;
      final result = await _extractMemberFromFile(
        package,
        version,
        filePath,
        content,
        className,
        method,
      );
      if (result != null) return result;
    }

    return _domainError(
      DomainError(
        error: DomainErrors.classNotFound,
        message: 'Class "$className" was not found in the source files of "$package".',
        suggestion:
            'Verify the class name is spelled correctly. '
            'Use browse_api_symbols with type=class to discover class names.',
      ),
    );
  }

  /// Tries to find [className] in [filePath] and extract [method] from it.
  ///
  /// Returns `null` when [className] is not declared in this file, allowing
  /// the caller to continue scanning other files.
  ///
  /// Returns a [CallToolResult] (success or `method_not_found`) when the class
  /// is found, regardless of whether [method] is present.
  Future<CallToolResult?> _extractMemberFromFile(
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

      // Class found in this file — extract the member (or return not-found).
      return _extractMember(members, className, method, content);
    }
    return null;
  }

  // ─── Top-level function extraction ────────────────────────────────────────

  Future<CallToolResult> _extractTopLevelFunction(
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
      _log(LoggingLevel.debug, 'get_method_body: index cache hit key=$indexCacheKey');
      symbols = await cachedIndex;
    } else {
      _log(LoggingLevel.debug, 'get_method_body: index cache miss key=$indexCacheKey');
      final indexFuture = _client.getApiIndex(package, version: effectiveVersion);
      _apiIndexCache.set(
        indexCacheKey,
        indexFuture.then(
          (r) => switch (r) {
            PubDevSuccess(:final value) => value,
            PubDevFailure() => <DartdocSymbol>[],
          },
        ),
        kApiDocsTtl,
      );
      _log(LoggingLevel.info, 'get_method_body: index HTTP request package=$package');
      final result = await indexFuture;
      if (result case PubDevFailure(:final error)) {
        _apiIndexCache.invalidate(indexCacheKey);
        return _domainError(
          error.error == DomainErrors.packageNotFound ? _kNoDocumentation : error,
        );
      }
      symbols = (result as PubDevSuccess<List<DartdocSymbol>>).value;
      // Overwrite the pre-set then-mapped future with the resolved value.
      _apiIndexCache.set(indexCacheKey, Future.value(symbols), kApiDocsTtl);
    }

    if (symbols.isEmpty) return _domainError(_kNoDocumentation);

    // Step 2: filter to functions matching `method`.
    //
    // Two lookup modes:
    // - Unqualified (e.g. "log"): match any function whose qualifiedName suffix
    //   (after the first ".") equals `method`.
    // - Qualified (e.g. "foo.log"): the caller is retrying after an
    //   ambiguous_symbol response; match the full qualifiedName exactly so that
    //   exactly one candidate is selected.
    final isQualified = method.contains('.');
    final unqualifiedName = isQualified
        ? method.substring(method.lastIndexOf('.') + 1)
        : method;

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
          error: DomainErrors.methodNotFound,
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
          error: DomainErrors.ambiguousSymbol,
          message:
              'Function "$method" is ambiguous — ${candidates.length} candidates found.',
          suggestion:
              'Retry with a fully qualified name from the alternatives list '
              '(e.g. pass the qualifiedName directly as the `method` value).',
          alternatives: candidates.map((s) => s.qualifiedName).toList(),
        ),
      );
    }

    // Step 3: load source files and search for the function.
    final filesResult = await _loadSourceFiles(package, effectiveVersion);
    if (filesResult case PubDevFailure(:final error)) return _domainError(error);
    final files = (filesResult as PubDevSuccess<Map<String, String>>).value;

    // Build the ordered search path list from the href hint.
    //
    // Two modes depending on whether the caller qualified the name:
    //
    // • Qualified retry (e.g. "foo.log" after ambiguous_symbol):
    //   Search ONLY the hint-derived paths.  Falling back to a global scan
    //   would risk returning the wrong homonymous function from another
    //   library — the whole point of the qualified retry is disambiguation.
    //   If the hint paths don't cover the file, method_not_found is the
    //   honest result.
    //
    // • Unqualified lookup (e.g. "log"):
    //   Put hint-derived paths first for speed, then scan all remaining Dart
    //   files as a fallback (original behaviour).
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
        return _successResult(content.substring(funcDecl.offset, funcDecl.end));
      }
    }

    return _domainError(
      DomainError(
        error: DomainErrors.methodNotFound,
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
      _log(LoggingLevel.debug, 'get_method_body: source cache hit key=$cacheKey');
      return PubDevSuccess(await cached);
    }

    _log(LoggingLevel.debug, 'get_method_body: source cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'get_method_body: HTTP tarball request package=$package');

    final fetchFuture = _client.getPackageSourceFiles(package, version);
    _sourceFilesCache.set(
      cacheKey,
      fetchFuture.then(
        (r) => r is PubDevSuccess<Map<String, String>> ? r.value : <String, String>{},
      ),
      kSourceFileTtl,
    );

    final result = await fetchFuture;
    if (result case PubDevSuccess(:final value)) {
      _sourceFilesCache.set(cacheKey, Future.value(value), kSourceFileTtl);
      return PubDevSuccess(value);
    }
    _sourceFilesCache.invalidate(cacheKey);

    // Preserve transient errors; re-wrap package_not_found with the package name.
    final error = (result as PubDevFailure<Map<String, String>>).error;
    return PubDevFailure(
      error.error == DomainErrors.packageNotFound
          ? _packageNotFoundError(package)
          : error,
    );
  }

  // ─── AST parsing & caching ─────────────────────────────────────────────────

  /// Returns the parsed AST for [filePath], computing and caching it on first call.
  ///
  /// Uses `throwIfDiagnostics: false` to tolerate malformed or partial Dart
  /// files without throwing. Callers may receive an AST with parse errors — they
  /// should still attempt symbol lookup on the (possibly incomplete) tree.
  Future<ParseStringResult> _getOrParseAst(
    String package,
    String version,
    String filePath,
    String content,
  ) async {
    final cacheKey = '$kAstSnapshotCachePrefix:$package:$version:$filePath';

    final cached = _astCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_method_body: AST cache hit key=$cacheKey');
      return cached;
    }

    _log(LoggingLevel.debug, 'get_method_body: parsing $filePath');

    final result = parseString(
      content: content,
      path: filePath,
      throwIfDiagnostics: false,
    );

    _astCache.set(cacheKey, Future.value(result), kAstSnapshotTtl);
    return result;
  }

  // ─── AST traversal helpers ─────────────────────────────────────────────────

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

  /// Extracts the source text of [method] from [members].
  ///
  /// When both a getter and setter share the same name, both are returned in
  /// one response, each prefixed by a `// getter` or `// setter` comment.
  ///
  /// Returns `method_not_found` when no match is found.
  static CallToolResult _extractMember(
    Iterable<ClassMember> members,
    String className,
    String method,
    String source,
  ) {
    final normalized = _normalizeMethodName(method);

    MethodDeclaration? getter;
    MethodDeclaration? setter;
    AstNode? other; // regular method, operator, or constructor

    for (final member in members) {
      if (member is MethodDeclaration) {
        if (member.name.lexeme != normalized) continue;
        if (member.isGetter) {
          getter = member;
        } else if (member.isSetter) {
          setter = member;
        } else {
          other = member;
        }
      } else if (member is ConstructorDeclaration) {
        // Unnamed constructor has name == null; named constructor lexeme matches.
        if ((member.name?.lexeme ?? '') == normalized) other = member;
      }
    }

    // Nothing matched.
    if (getter == null && setter == null && other == null) {
      return _domainError(
        DomainError(
          error: DomainErrors.methodNotFound,
          message: 'Member "$method" was not found in class "$className".',
          suggestion:
              'Verify the member name is spelled correctly. '
              'Use get_symbol_documentation to inspect all members of this class.',
        ),
      );
    }

    // Regular match only (method, operator, or constructor) — return unlabeled.
    if (getter == null && setter == null) {
      return _successResult(source.substring(other!.offset, other.end));
    }

    // Getter + setter pair — return both labeled.
    if (other == null) {
      if (getter != null && setter != null) {
        final g = source.substring(getter.offset, getter.end);
        final s = source.substring(setter.offset, setter.end);
        return _successResult('// getter\n$g\n\n// setter\n$s');
      }
      // Only getter or only setter — return unlabeled.
      final node = getter ?? setter!;
      return _successResult(source.substring(node.offset, node.end));
    }

    // Edge case: both a regular member and an accessor exist.
    // Return the regular member (method takes precedence over accessor).
    return _successResult(source.substring(other.offset, other.end));
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

  // ─── Utility helpers ───────────────────────────────────────────────────────

  /// Normalises [method] to the lexeme used in the AST.
  ///
  /// Two normalisation rules, applied in order:
  ///
  /// 1. `"new"` → `""` — matches an unnamed [ConstructorDeclaration] whose
  ///    `name` is `null`.  This is the canonical sentinel for the default
  ///    (unnamed) constructor, mirroring Dart 2.15+ `ClassName.new` syntax.
  /// 2. `"operator =="` → `"=="` — strips the `"operator "` prefix so that
  ///    both `"=="` and `"operator =="` resolve to the same AST node.
  static String _normalizeMethodName(String method) {
    if (method == 'new') return '';
    const prefix = 'operator ';
    if (method.startsWith(prefix)) return method.substring(prefix.length).trim();
    return method;
  }

  /// Returns candidate source file paths for a dartdoc href, ordered by
  /// likelihood.
  ///
  /// The first path segment of the href is the library name.  Two dominant
  /// Dart package layouts are tried in order:
  ///
  /// 1. `lib/<libraryName>.dart` — single-file library at the package root.
  /// 2. `lib/src/<libraryName>.dart` — src-convention layout.
  ///
  /// Examples:
  /// - `"http/get.html"` → `["lib/http.dart", "lib/src/http.dart"]`
  /// - `"io_client/IOClient-class.html"` → `["lib/io_client.dart", "lib/src/io_client.dart"]`
  ///
  /// Returns an empty list when the href has no path separator.
  static List<String> _hrefToSourcePaths(String href) {
    final slash = href.indexOf('/');
    if (slash <= 0) return const [];
    final libraryName = href.substring(0, slash);
    return ['lib/$libraryName.dart', 'lib/src/$libraryName.dart'];
  }

  // ─── Static error / result builders ───────────────────────────────────────

  static const _kNoDocumentation = DomainError(
    error: DomainErrors.noDocumentation,
    message: 'No API documentation found for this package.',
    suggestion: 'Verify the package name and that it has dartdoc output on pub.dev.',
  );

  static DomainError _packageNotFoundError(String package) => DomainError(
    error: DomainErrors.packageNotFound,
    message: 'Package "$package" not found on pub.dev.',
    suggestion: 'Verify the package name and try again.',
  );

  static CallToolResult _successResult(String text) =>
      CallToolResult(content: [TextContent(text: text)]);

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
