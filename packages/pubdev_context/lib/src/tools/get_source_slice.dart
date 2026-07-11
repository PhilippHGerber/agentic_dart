/// Handler for the `get_source_slice` MCP tool.
///
/// Extracts Dart source from a single package file in one of two modes.
///
/// **Line-range mode** (`file`, optional `lineStart`/`lineEnd`): returns the
/// exact requested 1-based inclusive line range with no truncation. When both
/// bounds are omitted the full file is returned verbatim. This supersedes the
/// old `get_package_source_file` tool.
///
/// **Symbol-bounded mode** (`file`, `symbolName`, optional `maxLines`): parses
/// the file with the Dart analyzer, locates the named declaration's AST node,
/// and returns its source. When `maxLines` is supplied and the node spans more
/// lines than that, the response is truncated to the signature, opening brace,
/// a `// ... N lines omitted ...` comment, and the closing brace. This
/// supersedes the old `get_method_body` tool.
///
/// ## Symbol resolution
///
/// `symbolName` is matched against declarations in the given `file` only — no
/// API index or href resolution is involved.
///
/// - A bare name (e.g. `Client`) matches a top-level class, mixin, enum,
///   extension, function, typedef, or variable of that name.
/// - A dotted name (e.g. `Client.send`) matches a member (method, constructor,
///   accessor, or field) named `send` inside the type `Client`. `new` resolves
///   to the unnamed constructor; `operator ==` and `==` both resolve to the
///   `operator ==` node.
///
/// ## Response shape
///
/// Every success response is a JSON object:
///
/// ```json
/// {
///   "resolvedVersion": "1.2.3",
///   "package": "http",
///   "file": "lib/http.dart",
///   "mode": "symbol",
///   "symbolName": "Client",
///   "lineStart": 40,
///   "effectiveLineEnd": 120,
///   "truncated": true,
///   "content": "class Client {\n  // ... 78 lines omitted ...\n}"
/// }
/// ```
///
/// `symbolName` is present only in symbol-bounded mode. `effectiveLineEnd`
/// always reports the true last line of the returned region (the symbol's real
/// end line even when truncated) so callers can drill in with a follow-up
/// line-range request.
///
/// ## Caches
///
/// Source files are resolved through the shared `sourceFiles` [KeyedCache]
/// facade (from `CacheRegistry`), keyed by `(package, resolvedVersion)`. That
/// facade is also shared by `get_throw_statements`, `list_package_source_files`,
/// and the `pubspec` package resource.
///
/// AST snapshots are resolved through the shared `ast` [KeyedCache] facade,
/// keyed by the file coordinate `(package, resolvedVersion, filepath)`.
/// That facade is shared with `get_throw_statements`, so the same source file
/// is never parsed twice across a single agent turn.
///
/// ## Domain errors
///
/// - `PACKAGE_NOT_FOUND`
/// - `SOURCE_FILE_NOT_FOUND` (file absent from the tarball)
/// - `SYMBOL_NOT_FOUND` (symbol-bounded mode, declaration not in the file)
/// - `INVALID_ARGUMENT` (`file` missing, or path contains `..` segments)
library;

import 'dart:convert';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../data/pub_client.dart';

/// Handles calls to the `get_source_slice` MCP tool.
///
/// Source-file loading is resolved through the shared `sourceFiles`
/// [KeyedCache] facade. The `ast` [KeyedCache] facade is shared with
/// `GetThrowStatementsHandler`, so the same file is never parsed twice across
/// a single agent turn.
final class GetSourceSliceHandler {
  /// Creates a [GetSourceSliceHandler].
  ///
  /// [sourceFiles] and [ast] are the shared [KeyedCache] facades (from
  /// `CacheRegistry`) — pass the same instances used by
  /// `GetThrowStatementsHandler` so the two handlers share both caches.
  GetSourceSliceHandler({
    required PubDevClient client,
    required KeyedCache<SourceFilesId, Map<String, String>> sourceFiles,
    required KeyedCache<AstSnapshotId, ParseStringResult> ast,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _sourceFiles = sourceFiles,
       _ast = ast,
       _log = log;

  final PubDevClient _client;
  final KeyedCache<SourceFilesId, Map<String, String>> _sourceFiles;
  final KeyedCache<AstSnapshotId, ParseStringResult> _ast;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_source_slice`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final package = (args['package'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;
    final rawFile = (args['file'] as String?) ?? '';
    final rawSymbol = args['symbolName'] as String?;
    final symbolName = (rawSymbol == null || rawSymbol.isEmpty) ? null : rawSymbol;
    final lineStart = _asInt(args['lineStart']);
    final lineEnd = _asInt(args['lineEnd']);
    final maxLines = _asInt(args['maxLines']);

    // Validate: `file` is always required.
    final file = _normalizePath(rawFile);
    if (file == null || file.isEmpty) {
      return _domainError(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'The `file` parameter is required and must not contain ".." segments.',
          suggestion:
              'Provide a relative path from the package root '
              '(e.g. "lib/src/server/prompts_support.dart"). '
              'Use list_package_source_files to discover available paths.',
        ),
      );
    }

    // Resolve effective version (S2).
    final String resolvedVersion;
    if (suppliedVersion != null) {
      resolvedVersion = suppliedVersion;
    } else {
      _log(LoggingLevel.info, 'get_source_slice: resolving latest stable version for $package');
      switch (await _client.resolveLatestStable(package)) {
        case PubDevFailure(:final error):
          return _domainError(error);
        case PubDevSuccess(:final value):
          resolvedVersion = value;
      }
      _log(LoggingLevel.debug, 'get_source_slice: resolved version=$resolvedVersion');
    }

    _log(
      LoggingLevel.info,
      'get_source_slice: package=$package version=$resolvedVersion file=$file '
      '${symbolName != null ? 'symbol=$symbolName' : 'lines=$lineStart..$lineEnd'}',
    );

    // Load the tarball (shared source cache).
    final Map<String, String> files;
    switch (await _loadSourceFiles(package, resolvedVersion)) {
      case PubDevFailure(:final error):
        return _domainError(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    final content = files[file];
    if (content == null) {
      return _domainError(
        DomainError(
          code: DomainErrors.sourceFileNotFound,
          message: 'Source file "$file" not found in $package $resolvedVersion.',
          suggestion: _closestMatchSuggestion(file, files.keys),
        ),
      );
    }

    return symbolName != null
        ? await _symbolBounded(
            package,
            resolvedVersion,
            file,
            content,
            symbolName,
            maxLines,
          )
        : _lineRange(resolvedVersion, package, file, content, lineStart, lineEnd);
  }

  // ─── Line-range mode ───────────────────────────────────────────────────────

  CallToolResult _lineRange(
    String resolvedVersion,
    String package,
    String file,
    String content,
    int? lineStart,
    int? lineEnd,
  ) {
    final lineInfo = LineInfo.fromContent(content);
    final lastLine = _lastLineNumber(content, lineInfo);

    // Both bounds omitted → whole file, verbatim.
    if (lineStart == null && lineEnd == null) {
      return _success(
        resolvedVersion: resolvedVersion,
        package: package,
        file: file,
        mode: 'line-range',
        lineStart: 1,
        effectiveLineEnd: lastLine,
        truncated: false,
        content: content,
      );
    }

    var start = lineStart ?? 1;
    var end = lineEnd ?? lastLine;
    if (start < 1) start = 1;
    if (start > lastLine) start = lastLine;
    if (end > lastLine) end = lastLine;
    if (end < start) end = start;

    final startOffset = lineInfo.getOffsetOfLine(start - 1);
    final endOffset = end < lineInfo.lineCount ? lineInfo.getOffsetOfLine(end) : content.length;
    var slice = content.substring(startOffset, endOffset);
    // Strip the single trailing line terminator that separates the last
    // requested line from the following line.
    if (slice.endsWith('\n')) slice = slice.substring(0, slice.length - 1);
    if (slice.endsWith('\r')) slice = slice.substring(0, slice.length - 1);

    return _success(
      resolvedVersion: resolvedVersion,
      package: package,
      file: file,
      mode: 'line-range',
      lineStart: start,
      effectiveLineEnd: end,
      truncated: false,
      content: slice,
    );
  }

  // ─── Symbol-bounded mode ───────────────────────────────────────────────────

  Future<CallToolResult> _symbolBounded(
    String package,
    String resolvedVersion,
    String file,
    String content,
    String symbolName,
    int? maxLines,
  ) async {
    final ast = await _getOrParseAst(package, resolvedVersion, file, content);
    final node = _findSymbol(ast.unit, symbolName);
    if (node == null) {
      return _domainError(
        DomainError(
          code: DomainErrors.symbolNotFound,
          message: 'Symbol "$symbolName" was not found in $file.',
          suggestion:
              'Verify the symbol name is spelled correctly. '
              'For a class member use "ClassName.memberName". '
              'Use find_symbols or browse_api_symbols to discover symbol names, '
              'or read the file with a line range instead.',
        ),
      );
    }

    final lineInfo = ast.lineInfo;
    final startLine = lineInfo.getLocation(node.offset).lineNumber;
    final endOffset = node.end > node.offset ? node.end - 1 : node.end;
    final endLine = lineInfo.getLocation(endOffset).lineNumber;
    final nodeLineCount = endLine - startLine + 1;
    final fullSource = content.substring(node.offset, node.end);

    // No truncation requested, or the node already fits.
    if (maxLines == null || nodeLineCount <= maxLines) {
      return _success(
        resolvedVersion: resolvedVersion,
        package: package,
        file: file,
        mode: 'symbol',
        symbolName: symbolName,
        lineStart: startLine,
        effectiveLineEnd: endLine,
        truncated: false,
        content: fullSource,
      );
    }

    final truncatedSource = _truncateToSignature(content, node, lineInfo, startLine, endLine);
    // If there was no brace body to elide, fall back to returning the full
    // source untruncated rather than an arbitrary line cut.
    if (truncatedSource == null) {
      return _success(
        resolvedVersion: resolvedVersion,
        package: package,
        file: file,
        mode: 'symbol',
        symbolName: symbolName,
        lineStart: startLine,
        effectiveLineEnd: endLine,
        truncated: false,
        content: fullSource,
      );
    }

    return _success(
      resolvedVersion: resolvedVersion,
      package: package,
      file: file,
      mode: 'symbol',
      symbolName: symbolName,
      lineStart: startLine,
      effectiveLineEnd: endLine,
      truncated: true,
      content: truncatedSource,
    );
  }

  /// Collapses [node]'s body to signature + opening brace + omission comment +
  /// closing brace. Returns `null` when the node has no brace-delimited body on
  /// a line strictly before its last line (nothing meaningful to elide).
  static String? _truncateToSignature(
    String content,
    AstNode node,
    LineInfo lineInfo,
    int startLine,
    int endLine,
  ) {
    final braceIdx = content.indexOf('{', node.offset);
    if (braceIdx < 0 || braceIdx >= node.end) return null;

    final braceLine = lineInfo.getLocation(braceIdx).lineNumber;
    final omittedCount = endLine - braceLine - 1;
    if (omittedCount <= 0) return null;

    // Signature: node start through the end of the opening-brace line.
    final sigEndOffset = braceLine < lineInfo.lineCount
        ? lineInfo.getOffsetOfLine(braceLine)
        : content.length;
    final signature = content.substring(node.offset, sigEndOffset).trimRight();

    // Closing: the whole last line of the node (leading indent preserved).
    final closing = content.substring(lineInfo.getOffsetOfLine(endLine - 1), node.end).trimRight();
    final closingIndent = closing.substring(0, closing.length - closing.trimLeft().length);

    return '$signature\n'
        '$closingIndent  // ... $omittedCount lines omitted ...\n'
        '$closing';
  }

  // ─── Symbol lookup ─────────────────────────────────────────────────────────

  /// Finds the AST node for [symbolName] within [unit], or `null` if absent.
  static AstNode? _findSymbol(CompilationUnit unit, String symbolName) {
    final dot = symbolName.indexOf('.');
    if (dot > 0) {
      final typeName = symbolName.substring(0, dot);
      final memberName = symbolName.substring(dot + 1);
      for (final decl in unit.declarations) {
        final members = _membersForDecl(decl, typeName);
        if (members == null) continue;
        final member = _findMember(members, memberName);
        if (member != null) return member;
        // Type found but member absent — keep scanning homonymous types.
      }
      return null;
    }

    for (final decl in unit.declarations) {
      if (_declMatches(decl, symbolName)) return decl;
    }
    return null;
  }

  /// Whether top-level [decl] declares a symbol named [name].
  static bool _declMatches(CompilationUnitMember decl, String name) {
    if (decl is ClassDeclaration) return decl.namePart.typeName.lexeme == name;
    if (decl is MixinDeclaration) return decl.name.lexeme == name;
    if (decl is EnumDeclaration) return decl.namePart.typeName.lexeme == name;
    if (decl is ExtensionDeclaration) return decl.name?.lexeme == name;
    if (decl is FunctionDeclaration) return decl.name.lexeme == name;
    if (decl is TypeAlias) return decl.name.lexeme == name;
    if (decl is TopLevelVariableDeclaration) {
      return decl.variables.variables.any((v) => v.name.lexeme == name);
    }
    return false;
  }

  /// Returns the class-member list for [decl] if it declares a type named
  /// [className], or `null` when [decl] is not a matching type declaration.
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

  /// Finds the member named [name] among [members], or `null` when absent.
  ///
  /// `new` matches the unnamed constructor; `operator ==` and `==` both match
  /// the `operator ==` node. Field declarations match on any of their variable
  /// names.
  static AstNode? _findMember(Iterable<ClassMember> members, String name) {
    final normalized = _normalizeMemberName(name);
    for (final member in members) {
      if (member is MethodDeclaration && member.name.lexeme == normalized) return member;
      if (member is ConstructorDeclaration && (member.name?.lexeme ?? '') == normalized) {
        return member;
      }
      if (member is FieldDeclaration) {
        if (member.fields.variables.any((v) => v.name.lexeme == name)) return member;
      }
    }
    return null;
  }

  /// Normalises [name] to the lexeme used in the AST.
  static String _normalizeMemberName(String name) {
    if (name == 'new') return '';
    const prefix = 'operator ';
    if (name.startsWith(prefix)) return name.substring(prefix.length).trim();
    return name;
  }

  // ─── Source file loading ───────────────────────────────────────────────────

  Future<PubDevResult<Map<String, String>>> _loadSourceFiles(String name, String version) =>
      _sourceFiles.resolve((name: name, version: version));

  // ─── AST parsing & caching ─────────────────────────────────────────────────

  /// Returns the parsed AST for [filePath], resolving through the shared `ast`
  /// facade so the same file is never parsed twice across a single agent turn.
  Future<ParseStringResult> _getOrParseAst(
    String package,
    String version,
    String filePath,
    String content,
  ) async {
    final result = await _ast.resolve((
      name: package,
      version: version,
      path: filePath,
      content: content,
    ));
    return switch (result) {
      PubDevSuccess(:final value) => value,
      // The `ast` facade's fetch closure always returns PubDevSuccess — see
      // CacheRegistry.ast.
      PubDevFailure(:final error) => throw StateError('unexpected AST parse failure: $error'),
    };
  }

  // ─── Utility helpers ───────────────────────────────────────────────────────

  /// The 1-based line number of the last content character.
  ///
  /// Ignores the phantom trailing empty line produced when [content] ends with
  /// a newline, so a file of N text lines reports N.
  static int _lastLineNumber(String content, LineInfo lineInfo) {
    if (content.isEmpty) return 1;
    return lineInfo.getLocation(content.length - 1).lineNumber;
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static String? _normalizePath(String raw) {
    final stripped = raw.startsWith('/') ? raw.substring(1) : raw;
    final segments = stripped.split('/');
    if (segments.any((s) => s == '..')) return null;
    return segments.join('/');
  }

  static String _closestMatchSuggestion(String path, Iterable<String> keys) {
    final filename = path.split('/').last.toLowerCase();
    final matches = keys.where((k) => k.split('/').last.toLowerCase() == filename).toList();
    if (matches.isNotEmpty) {
      final quoted = matches.take(3).map((p) => '"$p"').join(', ');
      return 'Did you mean: $quoted?';
    }
    return 'Call list_package_source_files to browse available paths.';
  }

  // ─── Result / error builders ───────────────────────────────────────────────

  static CallToolResult _success({
    required String resolvedVersion,
    required String package,
    required String file,
    required String mode,
    required int lineStart,
    required int effectiveLineEnd,
    required bool truncated,
    required String content,
    String? symbolName,
  }) => CallToolResult(
    content: [
      TextContent(
        text: jsonEncode({
          'resolvedVersion': resolvedVersion,
          'package': package,
          'file': file,
          'mode': mode,
          'symbolName': ?symbolName,
          'lineStart': lineStart,
          'effectiveLineEnd': effectiveLineEnd,
          'truncated': truncated,
          'content': content,
        }),
      ),
    ],
  );

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
