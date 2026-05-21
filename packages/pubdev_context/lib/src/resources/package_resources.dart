/// Resource handlers for the pub://package/{name}/ namespace.
///
/// Serves three parameterised [ResourceTemplate]s:
///   - `pub://package/{name}/readme`  — full README (text/markdown, 60 min TTL)
///   - `pub://package/{name}/example` — package example (text/markdown, 60 min TTL)
///   - `pub://package/{name}/api`     — dartdoc index.json symbols
///                                      (application/json, 60 min TTL)
///
/// The `api` resource shares its cache key format with [SearchApiSymbolsHandler]
/// (`api_index:<name>`) so that a warm symbol-search cache also satisfies this
/// resource and vice versa.
///
/// [CompletionsSupport] for the `{name}` parameter is handled in the server
/// layer ([PubMcpServer.handleComplete]) using the search cache.
///
/// See issue #11.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../cache/memory_cache.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import '../server.dart' show PubMcpServer;
import '../tools/search_api_symbols.dart';

/// Cache-key prefix for README entries.
///
/// Full key format: `$kReadmeCachePrefix:<packageName>`.
const kReadmeCachePrefix = 'readme';

/// Cache-key prefix for example entries.
///
/// Full key format: `$kExampleCachePrefix:<packageName>`.
const kExampleCachePrefix = 'example';

/// URI template string for the package README resource.
const kReadmeUriTemplate = 'pub://package/{name}/readme';

/// URI template string for the package example resource.
const kExampleUriTemplate = 'pub://package/{name}/example';

/// URI template string for the package API index resource.
const kApiUriTemplate = 'pub://package/{name}/api';

// ── Internal URI constants ────────────────────────────────────────────────────

const _kPackagePrefix = 'pub://package/';
const _kReadmeSuffix = '/readme';
const _kExampleSuffix = '/example';
const _kApiSuffix = '/api';

// ── Shared error value ────────────────────────────────────────────────────────

const _kPackageNotFound = DomainError(
  error: DomainErrors.packageNotFound,
  message: 'Package not found on pub.dev.',
  suggestion: 'Verify the package name and try again.',
  docs: 'https://pub.dev',
);

// ── PackageResourcesHandler ───────────────────────────────────────────────────

/// Handles MCP resource reads for the `pub://package/{name}/` namespace.
///
/// Register [kReadmeTemplate], [kExampleTemplate], and [kApiTemplate] with
/// addResourceTemplate and pass [handleReadResource] as the handler for all:
///
/// ```dart
/// addResourceTemplate(
///   PackageResourcesHandler.kReadmeTemplate,
///   handler.handleReadResource,
/// );
/// addResourceTemplate(
///   PackageResourcesHandler.kExampleTemplate,
///   handler.handleReadResource,
/// );
/// addResourceTemplate(
///   PackageResourcesHandler.kApiTemplate,
///   handler.handleReadResource,
/// );
/// ```
///
/// The `readme` resource fetches `GET /documentation/{name}/latest/` via
/// [PubDevClient.getFullReadme] and caches the result with [kReadmeTtl].
///
/// The `api` resource reads the dartdoc symbol index via [PubDevClient.getApiIndex]
/// and caches it under the same key used by [SearchApiSymbolsHandler]
/// (`api_index:<name>`), so both modules warm each other's cache.
///
/// Both resources return a [ReadResourceResult] whose content uses a structured
/// JSON [DomainError] payload for `package_not_found` and other failure cases.
final class PackageResourcesHandler {
  /// Creates a [PackageResourcesHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [readmeCache] is the shared TTL store
  /// for full README and example strings cached with [kReadmeTtl]. [apiIndexCache]
  /// must be the same instance used by [SearchApiSymbolsHandler] to enable shared
  /// cache warm-up — both modules use the key prefix [kApiIndexCachePrefix].
  /// [log] receives structured events at the appropriate [LoggingLevel].
  const PackageResourcesHandler({
    required PubDevClient client,
    required ResponseCache<String> readmeCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _readmeCache = readmeCache,
       _apiIndexCache = apiIndexCache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<String> _readmeCache;
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;
  final void Function(LoggingLevel, Object) _log;

  // ── Resource template descriptors ──────────────────────────────────────────

  /// [ResourceTemplate] descriptor for the `pub://package/{name}/readme` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  static final kReadmeTemplate = ResourceTemplate(
    uriTemplate: kReadmeUriTemplate,
    name: 'Package README',
    description:
        'Full README for a pub.dev package, extracted from the documentation '
        'page. Cached for 60 minutes.',
    mimeType: 'text/markdown',
  );

  /// [ResourceTemplate] descriptor for the `pub://package/{name}/example` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  static final kExampleTemplate = ResourceTemplate(
    uriTemplate: kExampleUriTemplate,
    name: 'Package example',
    description:
        'Example code for a pub.dev package, extracted from the example tab. '
        'Cached for 60 minutes.',
    mimeType: 'text/markdown',
  );

  /// [ResourceTemplate] descriptor for the `pub://package/{name}/api` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  /// The cache key for this resource is `api_index:<name>`, identical to the one
  /// used by [SearchApiSymbolsHandler], so both modules warm each other's cache.
  static final kApiTemplate = ResourceTemplate(
    uriTemplate: kApiUriTemplate,
    name: 'Package API index',
    description:
        'Dartdoc symbol index (index.json) for a pub.dev package as a JSON '
        'array. Shares its cache with the search_api_symbols tool. '
        'Cached for 60 minutes.',
    mimeType: 'application/json',
  );

  // ── Read handler ───────────────────────────────────────────────────────────

  /// Handles a [ReadResourceRequest] for the `readme`, `example`, or `api` resource.
  ///
  /// Returns `null` when [ReadResourceRequest.uri] does not match either template,
  /// letting the server try subsequent handlers. Returns a [ReadResourceResult] on
  /// success or when a structured [DomainError] (e.g. `package_not_found` on HTTP
  /// 404) is produced.
  Future<ReadResourceResult?> handleReadResource(ReadResourceRequest request) {
    final uri = request.uri;

    final readmeName = _parseName(uri, _kReadmeSuffix);
    if (readmeName != null) return _handleReadme(request, readmeName);

    final exampleName = _parseName(uri, _kExampleSuffix);
    if (exampleName != null) return _handleExample(request, exampleName);

    final apiName = _parseName(uri, _kApiSuffix);
    if (apiName != null) return _handleApi(request, apiName);

    return Future.value();
  }

  // ── Private: README ────────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleReadme(ReadResourceRequest request, String name) async {
    final cacheKey = '$kReadmeCachePrefix:$name';

    final cached = _readmeCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'readme resource: cache hit key=$cacheKey');
      return _readmeResult(request.uri, await cached);
    }

    _log(LoggingLevel.debug, 'readme resource: cache miss key=$cacheKey');

    final future = _client.getFullReadme(name);
    _readmeCache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => '',
        },
      ),
      kReadmeTtl,
    );

    _log(LoggingLevel.info, 'readme resource: HTTP request name=$name');

    final result = await future;
    return switch (result) {
      PubDevSuccess(:final value) => _readmeResult(request.uri, value),
      PubDevFailure(:final error) when error.error == DomainErrors.packageNotFound =>
        _domainErrorResult(request.uri, _kPackageNotFound),
      PubDevFailure(:final error) => _domainErrorResult(request.uri, error),
    };
  }

  // ── Private: example ──────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleExample(ReadResourceRequest request, String name) async {
    final cacheKey = '$kExampleCachePrefix:$name';

    final cached = _readmeCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'example resource: cache hit key=$cacheKey');
      return _readmeResult(request.uri, await cached);
    }

    _log(LoggingLevel.debug, 'example resource: cache miss key=$cacheKey');

    final future = _client.getExample(name);
    _readmeCache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => '',
        },
      ),
      kReadmeTtl,
    );

    _log(LoggingLevel.info, 'example resource: HTTP request name=$name');

    final result = await future;
    return switch (result) {
      PubDevSuccess(:final value) => _readmeResult(request.uri, value),
      PubDevFailure(:final error) when error.error == DomainErrors.packageNotFound =>
        _domainErrorResult(request.uri, _kPackageNotFound),
      PubDevFailure(:final error) => _domainErrorResult(request.uri, error),
    };
  }

  // ── Private: API index ─────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleApi(ReadResourceRequest request, String name) async {
    final cacheKey = '$kApiIndexCachePrefix:$name';

    final cached = _apiIndexCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'api resource: cache hit key=$cacheKey');
      return _apiResult(request.uri, await cached);
    }

    _log(LoggingLevel.debug, 'api resource: cache miss key=$cacheKey');

    final future = _client.getApiIndex(name);
    _apiIndexCache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => <DartdocSymbol>[],
        },
      ),
      kApiDocsTtl,
    );

    _log(LoggingLevel.info, 'api resource: HTTP request name=$name');

    final result = await future;
    return switch (result) {
      PubDevSuccess(:final value) => _apiResult(request.uri, value),
      PubDevFailure(:final error) when error.error == DomainErrors.packageNotFound =>
        _domainErrorResult(request.uri, _kPackageNotFound),
      PubDevFailure(:final error) => _domainErrorResult(request.uri, error),
    };
  }

  // ── Private: helpers ───────────────────────────────────────────────────────

  /// Extracts the package name from [uri] by stripping [_kPackagePrefix] and
  /// [suffix]. Returns `null` when the URI pattern does not match or the name
  /// segment is empty.
  static String? _parseName(String uri, String suffix) {
    if (!uri.startsWith(_kPackagePrefix)) return null;
    if (!uri.endsWith(suffix)) return null;
    final name = uri.substring(_kPackagePrefix.length, uri.length - suffix.length);
    return name.isEmpty ? null : name;
  }

  static ReadResourceResult _readmeResult(String uri, String text) => ReadResourceResult(
    contents: [TextResourceContents(uri: uri, text: text, mimeType: 'text/markdown')],
  );

  static ReadResourceResult _apiResult(String uri, List<DartdocSymbol> symbols) =>
      ReadResourceResult(
        contents: [
          TextResourceContents(
            uri: uri,
            text: jsonEncode(_symbolsToJson(symbols)),
            mimeType: 'application/json',
          ),
        ],
      );

  static ReadResourceResult _domainErrorResult(String uri, DomainError error) => ReadResourceResult(
    contents: [
      TextResourceContents(
        uri: uri,
        text: error.toJsonString(),
        mimeType: 'application/json',
      ),
    ],
  );

  static List<Map<String, Object?>> _symbolsToJson(List<DartdocSymbol> symbols) => [
    for (final s in symbols)
      {
        'name': s.name,
        'qualifiedName': s.qualifiedName,
        'href': s.href,
        'type': s.type,
        'desc': s.desc,
      },
  ];
}
