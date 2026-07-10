/// Resource handlers for the pub://package/{name}@{version}/ namespace.
///
/// Serves five parameterised [ResourceTemplate]s:
///   - `pub://package/{name}@{version}/readme`    — full README (text/markdown, 60 min TTL)
///   - `pub://package/{name}@{version}/example`   — package example (text/markdown, 60 min TTL)
///   - `pub://package/{name}@{version}/changelog` — full changelog (text/markdown, 60 min TTL)
///   - `pub://package/{name}@{version}/api`       — dartdoc index.json symbols
///                                                  (application/json, 60 min TTL)
///   - `pub://package/{name}@{version}/pubspec`   — raw pubspec.yaml extracted
///                                                  from the version tarball
///                                                  (text/plain, 60 min TTL)
///
/// `{version}` is mandatory. `latest` is a legal value and resolves to the
/// Latest Stable Version at request time via [PubDevClient.resolveLatestStable];
/// any other value is treated as an explicit version and echoed back verbatim.
/// Every successful response body is prefixed with a `[Resolved Version: x.y.z]`
/// header line so the LLM is grounded on the concrete version for follow-up
/// calls.
///
/// The `api` resource shares its cache key format with [BrowseApiSymbolsHandler]
/// (`api_index:<name>:<resolvedVersion>`) so that a warm symbol-search cache
/// also satisfies this resource and vice versa.
///
/// The `pubspec` resource shares its source-file cache key format
/// (`source:<name>:<resolvedVersion>`) with `get_source_slice`,
/// `list_package_source_files`, and `get_throw_statements`, so a single tarball
/// download warms every source-backed reader for that package version.
///
/// [CompletionsSupport] for the `{name}` and `{version}` parameters is handled
/// in the server layer ([PubMcpServer.handleComplete]) using the search and
/// versions caches.
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
import '../tools/browse_api_symbols.dart';

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
const kReadmeUriTemplate = 'pub://package/{name}@{version}/readme';

/// URI template string for the package example resource.
const kExampleUriTemplate = 'pub://package/{name}@{version}/example';

/// URI template string for the package changelog resource.
const kChangelogUriTemplate = 'pub://package/{name}@{version}/changelog';

/// URI template string for the package API index resource.
const kApiUriTemplate = 'pub://package/{name}@{version}/api';

/// URI template string for the package pubspec.yaml resource.
const kPubspecUriTemplate = 'pub://package/{name}@{version}/pubspec';

/// The `{version}` alias that resolves to the Latest Stable Version.
const kLatestVersionAlias = 'latest';

/// Cache-key prefix for extracted package source-file maps.
///
/// Full key format: `$kSourceFilesCachePrefix:<name>:<resolvedVersion>`. Shared
/// with `get_source_slice`, `list_package_source_files`, and
/// `get_throw_statements` so one tarball download warms every source reader.
const kSourceFilesCachePrefix = 'source';

/// The tarball path of the pubspec manifest, relative to the package root.
const kPubspecFileName = 'pubspec.yaml';

// ── Internal URI constants ────────────────────────────────────────────────────

const _kPackagePrefix = 'pub://package/';
const _kReadmeSuffix = '/readme';
const _kExampleSuffix = '/example';
const _kChangelogSuffix = '/changelog';
const _kApiSuffix = '/api';
const _kPubspecSuffix = '/pubspec';

// ── Shared error value ────────────────────────────────────────────────────────

const _kPackageNotFound = DomainError(
  code: DomainErrors.packageNotFound,
  message: 'Package not found on pub.dev.',
  suggestion: 'Verify the package name and try again.',
);

const _kPubspecNotFound = DomainError(
  code: DomainErrors.unexpectedResponse,
  message: 'pubspec.yaml not found in the package archive.',
  suggestion: 'Try again later or check the pub.dev status page.',
);

// ── PackageResourcesHandler ───────────────────────────────────────────────────

/// Handles MCP resource reads for the `pub://package/{name}@{version}/` namespace.
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
/// and caches it under the same key used by [BrowseApiSymbolsHandler]
/// (`api_index:<name>:<resolvedVersion>`), so both modules warm each other's cache.
///
/// The `pubspec` resource extracts `pubspec.yaml` from the version tarball via
/// [PubDevClient.getPackageSourceFiles] and shares the resulting source-file map
/// under the key `source:<name>:<resolvedVersion>` with `get_source_slice` and
/// `list_package_source_files`, so a single tarball download warms all three.
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
  /// be the same instance used by [BrowseApiSymbolsHandler] to enable shared
  /// cache warm-up — both modules use the key prefix [kApiIndexCachePrefix].
  /// [sourceFilesCache] must be the same instance used by `get_source_slice`
  /// and `list_package_source_files` so a single tarball download warms every
  /// source-backed reader — all use the key prefix [kSourceFilesCachePrefix].
  /// [log] receives structured events at the appropriate [LoggingLevel].
  const PackageResourcesHandler({
    required PubDevClient client,
    required ResponseCache<String> readmeCache,
    required ResponseCache<String> changelogCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required ResponseCache<Map<String, String>> sourceFilesCache,
    required void Function(LoggingLevel, Object) log,
  }) : _client = client,
       _readmeCache = readmeCache,
       _changelogCache = changelogCache,
       _apiIndexCache = apiIndexCache,
       _sourceFilesCache = sourceFilesCache,
       _log = log;

  final PubDevClient _client;
  final ResponseCache<String> _readmeCache;
  final ResponseCache<String> _changelogCache;
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;
  final ResponseCache<Map<String, String>> _sourceFilesCache;
  final void Function(LoggingLevel, Object) _log;

  // ── Resource template descriptors ──────────────────────────────────────────

  /// [ResourceTemplate] descriptor for the `pub://package/{name}@{version}/readme` resource.
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

  /// [ResourceTemplate] descriptor for the `pub://package/{name}@{version}/example` resource.
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

  /// [ResourceTemplate] descriptor for the `pub://package/{name}@{version}/changelog` resource.
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

  /// [ResourceTemplate] descriptor for the `pub://package/{name}@{version}/api` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  /// The cache key for this resource is `api_index:<name>:<resolvedVersion>`,
  /// identical to the one used by [BrowseApiSymbolsHandler], so both modules warm
  /// each other's cache.
  static final kApiTemplate = ResourceTemplate(
    uriTemplate: kApiUriTemplate,
    name: 'Package API index',
    description:
        'Read this only when you need the raw dartdoc symbol index — '
        'prefer browse_api_symbols for filtered, ranked symbol lookup. '
        'Use it for bulk symbol scanning or when browse_api_symbols pagination is insufficient.',
    mimeType: 'application/json',
  );

  /// [ResourceTemplate] descriptor for the `pub://package/{name}@{version}/pubspec` resource.
  ///
  /// Register this with addResourceTemplate alongside [handleReadResource].
  /// Returns the verbatim `pubspec.yaml` extracted from the version tarball,
  /// cached under `source:<name>:<resolvedVersion>` (shared with the other
  /// source-file readers).
  static final kPubspecTemplate = ResourceTemplate(
    uriTemplate: kPubspecUriTemplate,
    name: 'Package pubspec.yaml',
    description:
        "Read this for a package's raw pubspec.yaml at a specific version — "
        'its dependency constraints, SDK bounds, and declared platforms. '
        'Use it to inspect what a package itself depends on before adding it.',
    mimeType: 'text/plain',
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

    final readme = _parseRef(uri, _kReadmeSuffix);
    if (readme != null) return _handleReadme(request, readme.name, readme.version);

    final example = _parseRef(uri, _kExampleSuffix);
    if (example != null) return _handleExample(request, example.name, example.version);

    final changelog = _parseRef(uri, _kChangelogSuffix);
    if (changelog != null) return _handleChangelog(request, changelog.name, changelog.version);

    final api = _parseRef(uri, _kApiSuffix);
    if (api != null) return _handleApi(request, api.name, api.version);

    final pubspec = _parseRef(uri, _kPubspecSuffix);
    if (pubspec != null) return _handlePubspec(request, pubspec.name, pubspec.version);

    return Future.value();
  }

  /// Resolves [version] to a concrete version string.
  ///
  /// [kLatestVersionAlias] triggers [PubDevClient.resolveLatestStable]; any
  /// other value is an explicit version and is returned verbatim without an
  /// HTTP call.
  Future<PubDevResult<String>> _resolveVersion(String name, String version) {
    if (version == kLatestVersionAlias) return _client.resolveLatestStable(name);
    return Future.value(PubDevSuccess(version));
  }

  // ── Private: README ────────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleReadme(
    ReadResourceRequest request,
    String name,
    String version,
  ) async {
    final String resolvedVersion;
    switch (await _resolveVersion(name, version)) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    final cacheKey = '$kReadmeCachePrefix:$name';

    final cached = _readmeCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'readme resource: cache hit key=$cacheKey');
      return _textResult(request.uri, resolvedVersion, await cached);
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
      PubDevSuccess(:final value) => _textResult(request.uri, resolvedVersion, value),
      PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound =>
        _domainErrorResult(request.uri, _kPackageNotFound),
      PubDevFailure(:final error) => _domainErrorResult(request.uri, error),
    };
  }

  // ── Private: example ──────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleExample(
    ReadResourceRequest request,
    String name,
    String version,
  ) async {
    final String resolvedVersion;
    switch (await _resolveVersion(name, version)) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    final cacheKey = '$kExampleCachePrefix:$name';

    final cached = _readmeCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'example resource: cache hit key=$cacheKey');
      return _textResult(request.uri, resolvedVersion, await cached);
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
      PubDevSuccess(:final value) => _textResult(request.uri, resolvedVersion, value),
      PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound =>
        _domainErrorResult(request.uri, _kPackageNotFound),
      PubDevFailure(:final error) => _domainErrorResult(request.uri, error),
    };
  }

  // ── Private: changelog ────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleChangelog(
    ReadResourceRequest request,
    String name,
    String version,
  ) async {
    final String resolvedVersion;
    switch (await _resolveVersion(name, version)) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    final cacheKey = '$kChangelogCachePrefix:$name';

    final cached = _changelogCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'changelog resource: cache hit key=$cacheKey');
      return _textResult(request.uri, resolvedVersion, await cached);
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
      PubDevSuccess(:final value) => _textResult(request.uri, resolvedVersion, value),
      PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound =>
        _domainErrorResult(request.uri, _kPackageNotFound),
      PubDevFailure(:final error) => _domainErrorResult(request.uri, error),
    };
  }

  // ── Private: API index ─────────────────────────────────────────────────────

  Future<ReadResourceResult> _handleApi(
    ReadResourceRequest request,
    String name,
    String version,
  ) async {
    // Resolve `latest` to a concrete version (an explicit version is echoed
    // without an HTTP call) so the cache key is always version-qualified (never
    // bare `api_index:<name>`), matching the key format used by
    // [BrowseApiSymbolsHandler] for shared cache warm-up.
    final String resolvedVersion;
    switch (await _resolveVersion(name, version)) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    final cacheKey = '$kApiIndexCachePrefix:$name:$resolvedVersion';

    final cached = _apiIndexCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'api resource: cache hit key=$cacheKey');
      return _apiResult(request.uri, resolvedVersion, await cached);
    }

    _log(LoggingLevel.debug, 'api resource: cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'api resource: HTTP request name=$name');

    final result = await _client.getApiIndex(name, version: resolvedVersion);
    switch (result) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        // Cache only after a successful fetch. Storing a failure-mapped empty
        // list would poison the cache: every subsequent read within the TTL
        // window would return an empty index without retrying, letting a
        // single transient error (429/503/network) outlive the outage itself.
        _apiIndexCache.set(cacheKey, Future.value(value), kApiDocsTtl);
        return _apiResult(request.uri, resolvedVersion, value);
    }
  }

  // ── Private: pubspec ───────────────────────────────────────────────────────

  Future<ReadResourceResult> _handlePubspec(
    ReadResourceRequest request,
    String name,
    String version,
  ) async {
    // Resolve `latest` to a concrete version (an explicit version is echoed
    // without an HTTP call) so the source-file cache key is always
    // version-qualified, matching the format used by `get_source_slice` and
    // `list_package_source_files` for shared tarball warm-up.
    final String resolvedVersion;
    switch (await _resolveVersion(name, version)) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        resolvedVersion = value;
    }

    switch (await _loadSourceFiles(name, resolvedVersion)) {
      case PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound:
        return _domainErrorResult(request.uri, _kPackageNotFound);
      case PubDevFailure(:final error):
        return _domainErrorResult(request.uri, error);
      case PubDevSuccess(:final value):
        final pubspec = value[kPubspecFileName];
        if (pubspec == null) return _domainErrorResult(request.uri, _kPubspecNotFound);
        return _textResult(request.uri, resolvedVersion, pubspec, mimeType: 'text/plain');
    }
  }

  /// Loads the extracted source-file map for [name] at the concrete [version].
  ///
  /// Shares the `source:<name>:<version>` cache entry with `get_source_slice`
  /// and `list_package_source_files`, so a single tarball download serves every
  /// source reader. Stores the in-flight future before awaiting so concurrent
  /// callers share one download (cache-stampede prevention); a failed fetch is
  /// evicted so the next request retries cleanly rather than caching the error.
  Future<PubDevResult<Map<String, String>>> _loadSourceFiles(
    String name,
    String version,
  ) async {
    final cacheKey = '$kSourceFilesCachePrefix:$name:$version';

    final cached = _sourceFilesCache.get(cacheKey);
    if (cached != null) {
      _log(LoggingLevel.debug, 'pubspec resource: source cache hit key=$cacheKey');
      try {
        return PubDevSuccess(await cached);
      } on Object {
        // The in-flight request sharing this future failed; fall through to
        // issue an independent request.
      }
    }

    _log(LoggingLevel.debug, 'pubspec resource: source cache miss key=$cacheKey');
    _log(LoggingLevel.info, 'pubspec resource: HTTP tarball request name=$name');

    final completer = Completer<Map<String, String>>();
    _sourceFilesCache.set(cacheKey, completer.future, kSourceFileTtl);

    switch (await _client.getPackageSourceFiles(name, version)) {
      case PubDevSuccess(:final value):
        completer.complete(value);
        return PubDevSuccess(value);
      case PubDevFailure(:final error):
        completer.future.ignore();
        completer.completeError(StateError('fetch failed: ${error.code}'));
        _sourceFilesCache.invalidate(cacheKey);
        return PubDevFailure(error);
    }
  }

  // ── Private: helpers ───────────────────────────────────────────────────────

  /// Extracts the package `name` and `version` from [uri] by stripping
  /// [_kPackagePrefix] and [suffix] and splitting the remaining
  /// `{name}@{version}` segment on its first `@`.
  ///
  /// Returns `null` when the URI pattern does not match, when the `@` separator
  /// is absent, or when either the name or version segment is empty. Neither
  /// pub.dev package names nor version strings contain `@`, so splitting on the
  /// first occurrence is unambiguous.
  static ({String name, String version})? _parseRef(String uri, String suffix) {
    if (!uri.startsWith(_kPackagePrefix)) return null;
    if (!uri.endsWith(suffix)) return null;
    final segment = uri.substring(_kPackagePrefix.length, uri.length - suffix.length);
    final at = segment.indexOf('@');
    if (at <= 0) return null;
    final name = segment.substring(0, at);
    final version = segment.substring(at + 1);
    if (version.isEmpty) return null;
    return (name: name, version: version);
  }

  /// Prefixes [body] with the `[Resolved Version: x.y.z]` grounding header.
  static String _withHeader(String resolvedVersion, String body) =>
      '[Resolved Version: $resolvedVersion]\n$body';

  static ReadResourceResult _textResult(
    String uri,
    String resolvedVersion,
    String text, {
    String mimeType = 'text/markdown',
  }) => ReadResourceResult(
    contents: [
      TextResourceContents(
        uri: uri,
        text: _withHeader(resolvedVersion, text),
        mimeType: mimeType,
      ),
    ],
  );

  static ReadResourceResult _apiResult(
    String uri,
    String resolvedVersion,
    List<DartdocSymbol> symbols,
  ) => ReadResourceResult(
    contents: [
      TextResourceContents(
        uri: uri,
        text: _withHeader(resolvedVersion, jsonEncode(_symbolsToJson(symbols))),
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
