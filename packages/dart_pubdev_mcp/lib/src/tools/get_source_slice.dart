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
import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../data/domain_error.dart';
import 'arg_parsing.dart';
import 'line_range_slice.dart';
import 'symbol_bounded_slice.dart';
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
    final lineStart = asInt(args['lineStart']);
    final lineEnd = asInt(args['lineEnd']);
    final maxLines = asInt(args['maxLines']);

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
    final slice = sliceLineRange(content, lineStart, lineEnd);
    return _success(
      resolvedVersion: resolvedVersion,
      package: package,
      file: file,
      mode: 'line-range',
      lineStart: slice.lineStart,
      effectiveLineEnd: slice.effectiveLineEnd,
      truncated: false,
      content: slice.content,
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
    final slice = sliceSymbol(_astAccess, ast, symbolName, maxLines: maxLines);
    if (slice == null) {
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

    return _success(
      resolvedVersion: resolvedVersion,
      package: package,
      file: file,
      mode: 'symbol',
      symbolName: symbolName,
      lineStart: slice.lineStart,
      effectiveLineEnd: slice.effectiveLineEnd,
      truncated: slice.truncated,
      content: slice.content,
    );
  }

  // ─── Utility helpers ───────────────────────────────────────────────────────

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
