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
/// Source files and their parsed ASTs are resolved through the shared
/// `AstAccess`, which wraps the `sourceFiles` and `ast` `KeyedCache` facades
/// (from `CacheRegistry`). Both facades are shared with `get_throw_statements`
/// so a package's tarball is downloaded, and each of its files parsed, at
/// most once across a single agent turn.
///
/// ## Domain errors
///
/// - `PACKAGE_NOT_FOUND`
/// - `SOURCE_FILE_NOT_FOUND` (file absent from the tarball)
/// - `SYMBOL_NOT_FOUND` (symbol-bounded mode, declaration not in the file)
/// - `INVALID_ARGUMENT` (`file` missing, or path contains `..` segments)
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../data/domain_error.dart';
import 'tool_response.dart';
import 'version_resolver.dart';

/// Handles calls to the `get_source_slice` MCP tool.
///
/// Source-file loading and AST parsing are resolved through the shared
/// [AstAccess] — pass the same instance used by `GetThrowStatementsHandler`
/// so the two handlers share both caches.
final class GetSourceSliceHandler {
  /// Creates a [GetSourceSliceHandler].
  ///
  /// [versionResolver] resolves the Resolved Version, falling back to the
  /// Latest Stable Version when the caller omits one. [astAccess] resolves
  /// source files and their parsed ASTs — pass the same instance used by
  /// `GetThrowStatementsHandler` so the two handlers share both caches.
  GetSourceSliceHandler({
    required VersionResolver versionResolver,
    required AstAccess astAccess,
    required void Function(LoggingLevel, Object) log,
  }) : _versionResolver = versionResolver,
       _astAccess = astAccess,
       _log = log;

  final VersionResolver _versionResolver;
  final AstAccess _astAccess;
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
      return ToolResponse.error(
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
    switch (await _versionResolver.resolve(
      package: package,
      supplied: suppliedVersion,
      tool: 'get_source_slice',
    )) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    _log(
      LoggingLevel.info,
      'get_source_slice: package=$package version=$resolvedVersion file=$file '
      '${symbolName != null ? 'symbol=$symbolName' : 'lines=$lineStart..$lineEnd'}',
    );

    // Symbol-bounded mode needs the parsed AST; line-range mode needs only the
    // raw content, so each mode resolves through the matching AstAccess method.
    if (symbolName != null) {
      switch (await _astAccess.unit(package, resolvedVersion, file)) {
        case PubDevFailure(:final error):
          return ToolResponse.error(error);
        case PubDevSuccess(:final value):
          return _symbolBounded(package, resolvedVersion, file, value, symbolName, maxLines);
      }
    }

    switch (await _astAccess.fileText(package, resolvedVersion, file)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _lineRange(resolvedVersion, package, file, value, lineStart, lineEnd);
    }
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

  CallToolResult _symbolBounded(
    String package,
    String resolvedVersion,
    String file,
    ParseStringResult ast,
    String symbolName,
    int? maxLines,
  ) {
    final content = ast.content;
    final node = _findSymbol(ast.unit, symbolName);
    if (node == null) {
      return ToolResponse.error(
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
  ///
  /// A bare name matches a top-level declaration directly. A dotted name
  /// (`Type.member`) delegates to [AstAccess.member] for the class-member
  /// lookup and name normalization, taking the first match when an accessor
  /// pair shares the member name.
  AstNode? _findSymbol(CompilationUnit unit, String symbolName) {
    final dot = symbolName.indexOf('.');
    if (dot > 0) {
      final typeName = symbolName.substring(0, dot);
      final memberName = symbolName.substring(dot + 1);
      final members = _astAccess.member(unit, typeName, memberName: memberName);
      return members == null || members.isEmpty ? null : members.first;
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
  }) => ToolResponse.ok({
    'package': package,
    'file': file,
    'mode': mode,
    'symbolName': ?symbolName,
    'lineStart': lineStart,
    'effectiveLineEnd': effectiveLineEnd,
    'truncated': truncated,
    'content': content,
  }, resolvedVersion: resolvedVersion);
}
