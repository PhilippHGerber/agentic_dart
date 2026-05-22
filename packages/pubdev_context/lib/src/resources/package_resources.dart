/// Resource handlers for the pub://package/{name}/ namespace.
///
/// Serves four parameterised [ResourceTemplate]s:
///   - `pub://package/{name}/readme`     — full README (text/markdown, 60 min TTL)
///   - `pub://package/{name}/example`    — package example (text/markdown, 60 min TTL)
///   - `pub://package/{name}/changelog`  — full changelog (text/markdown, 60 min TTL)
///   - `pub://package/{name}/api`        — dartdoc index.json symbols
///                                         (application/json, 60 min TTL)
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

/// Cache-key prefix for raw changelog text entries.
///
/// Full key format: `$kChangelogCachePrefix:<packageName>`.
const kChangelogCachePrefix = 'changelog';

/// URI template string for the package README resource.
const kReadmeUriTemplate = 'pub://package/{name}/readme';

/// URI template string for the package example resource.
const kExampleUriTemplate = 'pub://package/{name}/example';

/// URI template string for the package changelog resource.
const kChangelogUriTemplate = 'pub://package/{name}/changelog';

/// URI template string for the package API index resource.
const kApiUriTemplate = 'pub://package/{name}/api';

// ── Internal URI constants ────────────────────────────────────────────────────

const _kPackagePrefix = 'pub://package/';
const _kReadmeSuffix = '/readme';
const _kExampleSuffix = '/example';
const _kChangelogSuffix = '/changelog';
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
/// Register [kReadmeTemplate], [kExampleTemplate], [kChangelogTemplate], and
/// [kApiTemplate] with addResourceTemplate and pass [handleReadResource] as the
/// handler for all:
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
///   PackageResourcesHandler.kChangelogTemplate,
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
/// The `changelog` resource fetches `GET /packages/{name}/changelog` via
/// [PubDevClient.getChangelog] and caches the raw markdown text with
/// [kChangelogRawTtl] under key `changelog:<name>`. This is separate from the
/// parsed `ChangelogEntry` list cached by `GetChangelogHandler`.
///
/// The `api` resource reads the dartdoc symbol index via [PubDevClient.getApiIndex]
/// and caches it under the same key used by [SearchApiSymbolsHandler]
/// (`api_index:<name>`), so both modules warm each other's cache.
///
/// All resources return a [ReadResourceResult] whose content uses a structured
/// JSON [DomainError] payload for `package_not_found` and other failure cases.
final class PackageResourcesHandler {
  /// Creates a [PackageResourcesHandler].
  ///
  /// [client] is the pub.dev HTTP gateway. [readmeCache] is the shared TTL store
  /// for full README and example strings cached with [kReadmeTtl].
  /// [changelogCache] is a dedicated store for raw changelog markdown strings
  /// cached with [kChangelogRawTtl] — it is separate from the parsed
  /// `ChangelogEntry` cache used by `GetChangelogHandler`. [apiIndexCache] must
  /// be the same instance used by [SearchApiSymbolsHandler] to enable shared
  /// cache warm-up — both modules use the key prefix [kApiIndexCachePrefix].
  /// [log] receives structured events at the appropriate [LoggingLevel].
  const PackageResourcesHandler({
    required PubDevClient client,
    required ResponseCache<String> readmeCache,
    required ResponseCache<String> changelogCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _readmeCache = readmeCache,
       _changelogCache = changelogCache,
       _apiIndexCache = apiIndexCache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<String> _readmeCache;
  final ResponseCache<String> _changelogCache;
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
        'Read this when you need the full README for a package — '
        'it is more complete than the excerpt returned by get_package. '
        'Use it when the user asks how to set up or use a package, or before writing initialisation code.',
    mimeType: 'text/markdown',
  );

  /// [ResourceTemplate] descriptor for the `pub://package/{name}/example` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  static final kExampleTemplate = ResourceTemplate(
    uriTemplate: kExampleUriTemplate,
    name: 'Package example',
    description:
        "Read this to retrieve working example code from the package's example tab. "
        'Use it before writing setup or usage code — copy patterns from here instead of guessing.',
    mimeType: 'text/markdown',
  );

  /// [ResourceTemplate] descriptor for the `pub://package/{name}/changelog` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  /// The cached entry stores raw changelog markdown text under `changelog:<name>`
  /// and is separate from the parsed `ChangelogEntry` cache used by
  /// `GetChangelogHandler`.
  static final kChangelogTemplate = ResourceTemplate(
    uriTemplate: kChangelogUriTemplate,
    name: 'Package changelog',
    description:
        'Read this for the complete, unstructured changelog text. '
        'Prefer get_changelog when you need structured entries with from_version filtering and breaking flags. '
        'Use this only when you need the full raw markdown.',
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
        'Read this only when you need the raw dartdoc symbol index — '
        'prefer search_api_symbols for filtered, ranked symbol lookup. '
        'Use it for bulk symbol scanning or when search_api_symbols pagination is insufficient.',
    mimeType: 'application/json',
  );

  // ── Read handler ───────────────────────────────────────────────────────────

  /// Handles a [ReadResourceRequest] for the `readme`, `example`, `changelog`,
  /// or `api` resource.
  ///
  /// Returns `null` when [ReadResourceRequest.uri] does not match any template,
  /// letting the server try subsequent handlers. Returns a [ReadResourceResult] on
  /// success or when a structured [DomainError] (e.g. `package_not_found` on HTTP
  /// 404) is produced.
  Future<ReadResourceResult?> handleReadResource(ReadResourceRequest request) {
    final uri = request.uri;

    final readmeName = _parseName(uri, _kReadmeSuffix);
    if (readmeName != null) return _handleReadme(request, readmeName);

    final exampleName = _parseName(uri, _kExampleSuffix);
    if (exampleName != null) return _handleExample(request, exampleName);

    final changelogName = _parseName(uri, _kChangelogSuffix);
    if (changelogName != null) return _handleChangelog(request, changelogName);

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

  // ── Private: changelog ────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleChangelog(ReadResourceRequest request, String name) async {
    final cacheKey = '$kChangelogCachePrefix:$name';

    final cached = _changelogCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'changelog resource: cache hit key=$cacheKey');
      return _readmeResult(request.uri, await cached);
    }

    _log(LoggingLevel.debug, 'changelog resource: cache miss key=$cacheKey');

    final future = _client.getChangelog(name);
    _changelogCache.set(
      cacheKey,
      future.then(
        (r) => switch (r) {
          PubDevSuccess(:final value) => value,
          PubDevFailure() => '',
        },
      ),
      kChangelogRawTtl,
    );

    _log(LoggingLevel.info, 'changelog resource: HTTP request name=$name');

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
