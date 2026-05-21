/// Handler for the `get_symbol_documentation` MCP tool.
///
/// Fetches the full dartdoc page for a specific API symbol and returns its
/// content as plain text. The `href` input must come from a prior
/// `search_api_symbols` call — this tool is the second step in the
/// symbol-exploration workflow.
///
/// Cache key format: `symbol_doc:<package>:<href>` (see [kSymbolDocCachePrefix]).
/// Results are cached with a [kSymbolDocTtl] TTL.
///
/// Domain errors:
/// - `symbol_not_found`: the href resolves to HTTP 404.
///
/// See issue #23.
library;

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/pub_client.dart';

/// Cache-key prefix for symbol documentation entries.
///
/// Full key format: `$kSymbolDocCachePrefix:<package>:<href>`.
const kSymbolDocCachePrefix = 'symbol_doc';

/// Handles calls to the `get_symbol_documentation` MCP tool.
///
/// Consults `cache` before issuing HTTP requests; stores results with
/// [kSymbolDocTtl]. Logs cache hits at [LoggingLevel.debug] and HTTP requests
/// at [LoggingLevel.info] via `log`.
final class GetSymbolDocumentationHandler {
  /// Creates a [GetSymbolDocumentationHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [cache] is the TTL store for
  /// symbol documentation pages. [log] receives structured log events at
  /// the appropriate [LoggingLevel].
  const GetSymbolDocumentationHandler({
    required PubDevClient client,
    required ResponseCache<String> cache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _cache = cache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<String> _cache;
  final void Function(LoggingLevel, Object) _log;

  /// Handles a [CallToolRequest] for `get_symbol_documentation`.
  ///
  /// Consults the cache first, then calls [PubDevClient.getSymbolDoc] on a miss.
  /// Returns [CallToolResult.isError] `true` with a structured JSON payload on
  /// `symbol_not_found` or other domain failures.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};

    final package = (args['package'] as String?) ?? '';
    final href = (args['href'] as String?) ?? '';

    _log(LoggingLevel.info, 'get_symbol_documentation: package=$package href=$href');

    final cacheKey = '$kSymbolDocCachePrefix:$package:$href';

    final cached = _cache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'get_symbol_documentation: cache hit key=$cacheKey');
      final text = await cached;
      if (text.isEmpty) return _domainError(_kSymbolNotFound);
      return _successResult(text);
    }

    _log(LoggingLevel.debug, 'get_symbol_documentation: cache miss key=$cacheKey');

    final future = _client.getSymbolDoc(package, href);
    _cache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => '',
        },
      ),
      kSymbolDocTtl,
    );

    _log(LoggingLevel.info, 'get_symbol_documentation: HTTP request package=$package href=$href');

    final result = await future;
    return switch (result) {
      PubDevSuccess(:final value) => _successResult(value),
      PubDevFailure(:final error) => _domainError(error),
    };
  }

  static const _kSymbolNotFound = DomainError(
    error: DomainErrors.symbolNotFound,
    message: 'Symbol documentation page not found.',
    suggestion: 'Verify the href came from search_api_symbols and the package has dartdoc output.',
  );

  static CallToolResult _successResult(String text) =>
      CallToolResult(content: [TextContent(text: text)]);

  static CallToolResult _domainError(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
