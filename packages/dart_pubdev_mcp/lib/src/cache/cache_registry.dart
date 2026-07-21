/// Constructs and owns every [KeyedCache] instance used by `PubMcpServer`.
///
/// [CacheRegistry] is the single home for cache-key formats, TTLs, and fetch
/// wiring for every handler-layer cached artifact — `PubMcpServer`'s sole
/// cache dependency.
library;

import 'dart:convert';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:http/http.dart' as http;

import '../data/changelog_parser.dart';
import '../data/domain_error.dart';
import '../data/models.dart';
import '../data/pub_client.dart';
import '../data/sdk_client.dart';
import '../resources/scoring_content.dart';
import '../trace/wire_trace.dart';
import 'keyed_cache.dart';
import 'memory_cache.dart';

/// TTL applied to search-result entries.
const Duration kSearchResultsTtl = Duration(minutes: 5);

/// TTL applied to package version-list entries (parsed `PackageVersion` lists).
///
/// Matches [kPackageMetadataTtl]: both derive from `GET /api/packages/{name}`,
/// so a newly published version becomes visible within the same short window.
const Duration kPackageVersionsTtl = Duration(minutes: 15);

/// TTL applied to changelog entries (parsed `ChangelogEntry` lists).
const Duration kChangelogTtl = Duration(minutes: 15);

/// TTL applied to API-documentation index (`index.json`) entries.
const Duration kApiDocsTtl = Duration(hours: 1);

/// TTL applied to README entries.
const Duration kReadmeTtl = Duration(hours: 1);

/// TTL applied to symbol documentation page entries.
const Duration kSymbolDocTtl = Duration(hours: 1);

/// TTL applied to source file map entries (path → content maps).
const Duration kSourceFileTtl = Duration(hours: 1);

/// TTL applied to AST snapshot entries (parsed `ParseStringResult` objects).
const Duration kAstSnapshotTtl = Duration(hours: 1);

/// TTL applied to meta-resource entries (scoring, SDK versions).
const Duration kMetaResourcesTtl = Duration(hours: 24);

/// Identity for a [PackageDetail] entry: a package `name` at a concrete
/// `version`.
///
/// `pinned` is `true` when the caller supplied `version` explicitly — the
/// fetch closure then calls [PubDevClient.getPackageVersion], which returns
/// `versionsRecent` for that one version only. It is `false` when `version`
/// was resolved as the Latest Stable Version, so the fetch closure calls
/// [PubDevClient.getPackage] instead, whose fuller `versionsRecent` list both
/// `get_package` and `compare_packages` preserve from before this facade
/// existed. `pinned` does not affect the cache key — only which client call
/// the fetch closure makes on a miss.
typedef PackageDetailId = ({String name, String version, bool pinned});

/// Identity for a dartdoc symbol index entry: a package `name` at a concrete
/// `version`.
///
/// Shared by every tool that resolves the dartdoc `index.json` for a package —
/// `browse_api_symbols`, `find_symbols`, `get_api_diff`, and
/// `get_symbol_documentation` — so a warm entry serves all four without a
/// second pub.dev fetch.
typedef ApiIndexId = ({String name, String version});

/// Identity for an extracted package source-file map: a package `name` at a
/// concrete `version`.
///
/// Shared by every reader of a package's tarball contents —
/// `list_package_source_files`, `get_source_slice`, `get_throw_statements`,
/// and the `pubspec` package resource — so one tarball download serves every
/// source-backed reader for that package version.
typedef SourceFilesId = ({String name, String version});

/// Identity for a parsed-AST snapshot: the file coordinate (`name`,
/// `version`, `path`) plus the already-loaded `content` to parse on a miss.
///
/// `content` does not affect the cache key — only `name`, `version`, and
/// `path` do, matching how [PackageDetailId]'s `pinned` field carries
/// fetch-only data alongside the identity. Shared by `get_source_slice` and
/// `get_throw_statements` so the same file is never parsed twice across a
/// single agent turn.
typedef AstSnapshotId = ({String name, String version, String path, String content});

/// Identity for a search-results page: the full query tuple `search_packages`
/// accepts.
///
/// Shared with the server's `{name}` autocomplete, which scans every live
/// entry via [KeyedCache.entries] — cache-only, no pub.dev call.
typedef SearchResultsId = ({
  String query,
  int limit,
  int page,
  String? sdk,
  String sort,
  String? platform,
});

/// Identity for a package's full published-version list: a package `name`.
///
/// Shared with the server's `{version}` autocomplete, which reads the cached
/// list for the named package via [KeyedCache.peek] — cache-only, no pub.dev
/// call.
typedef VersionListId = ({String name});

/// Identity for a package's full parsed changelog entry list: a package
/// `name`.
///
/// Single-owner: `get_changelog` is the only reader. No version segment — the
/// full changelog text covers every released version, so one cached parse
/// serves every `fromVersion`/`versionLimit` query for the package.
typedef ChangelogEntriesId = ({String name});

/// Discriminates which raw markdown artifact a [ReadmeId] identifies.
///
/// The three kinds share a facade (and, historically, a single store) because
/// all are single-owner raw-text reads on `PackageResourcesHandler` with the
/// same TTL policy; `kind` selects both the cache-key prefix and which
/// [PubDevClient] method the fetch closure calls.
enum ReadmeKind {
  /// The full README, fetched via [PubDevClient.getFullReadme].
  readme,

  /// The package example page, fetched via [PubDevClient.getExample].
  example,

  /// The raw changelog markdown text, fetched via [PubDevClient.getChangelog].
  changelog,
}

/// Identity for a raw markdown resource body: a package `name` plus which
/// [ReadmeKind] of body is requested.
///
/// Single-owner: `PackageResourcesHandler` is the only reader, for the
/// `readme`, `example`, and `changelog` package resources.
typedef ReadmeId = ({String name, ReadmeKind kind});

/// Identity for an individual dartdoc symbol documentation page: a package
/// `package` at a concrete `version`, plus the page's `href`.
///
/// Single-owner: `get_symbol_documentation` is the only reader. The version
/// segment is always a concrete semver — the latest-stable version is resolved
/// before the identity is built — so requests for different versions never
/// reuse each other's cached docs.
typedef SymbolDocId = ({String package, String version, String href});

/// Fixed identities for the two cacheable `pub://meta/` resources.
///
/// `scoring` never fails — its fetch closure always returns [PubDevSuccess]
/// with the compile-time [kScoringContent]. `sdkVersions` fetches two Google
/// Storage endpoints; a request failure or malformed payload maps to a
/// [PubDevFailure] carrying a [DomainErrors.unexpectedResponse] error.
enum MetaId {
  /// `pub://meta/scoring` — the compile-time pub.dev scoring guide.
  scoring,

  /// `pub://meta/sdk-versions` — the current stable Dart and Flutter SDK
  /// versions.
  sdkVersions,
}

/// Constructs and owns every [KeyedCache] instance, one per cached artifact.
///
/// `PubMcpServer` obtains each handler's facade from here instead of building
/// a raw [ResponseCache] itself, so every key format, TTL, and fetch closure
/// for a migrated artifact lives in one file.
final class CacheRegistry {
  /// Creates a [CacheRegistry] wired to [client].
  ///
  /// [trace] is forwarded to every constructed [KeyedCache] so Wire Trace hit
  /// logging is unchanged. [clock] is forwarded for test control of TTL
  /// expiry; production callers omit it and get wall-clock time. [metaHttpClient]
  /// is the HTTP client the `meta` facade uses for the two Google Storage SDK-
  /// version endpoints — a separate boundary from [client]'s pub.dev calls.
  /// Supply it in tests to mock those endpoints; production callers may omit
  /// it and get an internally-created client that [dispose] closes. [sdkClient]
  /// is the `codeload.github.com` gateway `sdkSourceFiles` fetches through —
  /// pass the same instance wired to [client]'s `TarballDiskCache` so SDK and
  /// pub.dev tarballs share one on-disk cache directory (ADR 0006); production
  /// callers may omit it and get an internally-created client that [dispose]
  /// closes.
  factory CacheRegistry({
    required PubDevClient client,
    WireTrace? trace,
    Clock? clock,
    http.Client? metaHttpClient,
    SdkClient? sdkClient,
  }) => CacheRegistry._(
    client: client,
    trace: trace,
    clock: clock,
    metaHttpClient: metaHttpClient ?? http.Client(),
    metaHttpOwned: metaHttpClient == null,
    sdkClient: sdkClient ?? SdkClient(),
    sdkClientOwned: sdkClient == null,
  );

  CacheRegistry._({
    required PubDevClient client,
    required http.Client metaHttpClient,
    required bool metaHttpOwned,
    required SdkClient sdkClient,
    required bool sdkClientOwned,
    WireTrace? trace,
    Clock? clock,
  }) : _metaHttpClient = metaHttpClient,
       _metaHttpOwned = metaHttpOwned,
       _sdkClient = sdkClient,
       _sdkClientOwned = sdkClientOwned,
       packageDetail = KeyedCache<PackageDetailId, PackageDetail>(
         keyOf: (id) => 'package:${id.name}:${id.version}',
         ttl: kPackageMetadataTtl,
         fetch: (id) =>
             id.pinned ? client.getPackageVersion(id.name, id.version) : client.getPackage(id.name),
         clock: clock,
         trace: trace,
       ),
       apiIndex = KeyedCache<ApiIndexId, List<DartdocSymbol>>(
         keyOf: (id) => 'api_index:${id.name}:${id.version}',
         ttl: kApiDocsTtl,
         fetch: (id) async {
           final result = await client.getApiIndex(id.name, version: id.version);
           return switch (result) {
             PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound =>
               const PubDevSuccess(<DartdocSymbol>[]),
             _ => result,
           };
         },
         clock: clock,
         trace: trace,
       ),
       sourceFiles = KeyedCache<SourceFilesId, Map<String, String>>(
         keyOf: (id) => 'source:${id.name}:${id.version}',
         ttl: kSourceFileTtl,
         fetch: (id) async {
           final result = await client.getPackageSourceFiles(id.name, id.version);
           return switch (result) {
             PubDevFailure(:final error) when error.code == DomainErrors.packageNotFound =>
               PubDevFailure(
                 DomainError(
                   code: DomainErrors.packageNotFound,
                   message: 'Package "${id.name}" not found on pub.dev.',
                   suggestion: 'Verify the package name and try again.',
                 ),
               ),
             _ => result,
           };
         },
         clock: clock,
         trace: trace,
       ),
       ast = KeyedCache<AstSnapshotId, ParseStringResult>(
         keyOf: (id) => 'ast:${id.name}:${id.version}:${id.path}',
         ttl: kAstSnapshotTtl,
         fetch: (id) async => PubDevSuccess(
           parseString(content: id.content, path: id.path, throwIfDiagnostics: false),
         ),
         clock: clock,
         trace: trace,
       ),
       // `id.name` is the fixed per-SDK cache name ('dart_sdk' / 'flutter_sdk')
       // every handler passes — see ADR 0006's cache-key scheme.
       sdkSourceFiles = KeyedCache<SourceFilesId, Map<String, String>>(
         keyOf: (id) => 'sdk_source:${id.name}:${id.version}',
         ttl: kSourceFileTtl,
         fetch: (id) async {
           final isFlutter = id.name == 'flutter_sdk';
           final result = await sdkClient.getSourceFiles(
             sdkId: isFlutter ? 'flutter' : 'dart',
             cacheName: id.name,
             owner: isFlutter ? 'flutter' : 'dart-lang',
             repo: isFlutter ? 'flutter' : 'sdk',
             ref: id.version,
           );
           return switch (result) {
             // The Flutter tag tarball's packages/<name>/lib/... layout
             // already matches the installed layout — no stripping needed,
             // unlike the Dart SDK's sdk/ wrapper (see ADR 0006).
             PubDevSuccess(:final value) => PubDevSuccess(
               isFlutter ? value : _stripDartSdkRepoPrefix(value),
             ),
             PubDevFailure() => result,
           };
         },
         clock: clock,
         trace: trace,
       ),
       sdkAst = KeyedCache<AstSnapshotId, ParseStringResult>(
         keyOf: (id) => 'sdk_ast:${id.name}:${id.version}:${id.path}',
         ttl: kAstSnapshotTtl,
         fetch: (id) async => PubDevSuccess(
           parseString(content: id.content, path: id.path, throwIfDiagnostics: false),
         ),
         clock: clock,
         trace: trace,
       ),
       searchResults = KeyedCache<SearchResultsId, List<PackageSummary>>(
         keyOf: (id) =>
             'search:${id.query}:${id.limit}:${id.page}:${id.sdk ?? ''}:${id.sort}:${id.platform ?? ''}',
         ttl: kSearchResultsTtl,
         fetch: (id) => client.search(
           id.query,
           sort: id.sort,
           sdk: id.sdk,
           platform: id.platform,
           page: id.page,
           limit: id.limit,
         ),
         clock: clock,
         trace: trace,
       ),
       versionList = KeyedCache<VersionListId, List<PackageVersion>>(
         keyOf: (id) => 'versions:${id.name}',
         ttl: kPackageVersionsTtl,
         fetch: (id) => client.listVersions(id.name),
         clock: clock,
         trace: trace,
       ),
       changelog = KeyedCache<ChangelogEntriesId, List<ChangelogEntry>>(
         keyOf: (id) => 'changelog:${id.name}',
         ttl: kChangelogTtl,
         fetch: (id) async {
           final result = await client.getChangelog(id.name);
           return switch (result) {
             PubDevSuccess(:final value) => PubDevSuccess(parseChangelogText(value)),
             PubDevFailure(:final error) => PubDevFailure(error),
           };
         },
         clock: clock,
         trace: trace,
       ),
       readme = KeyedCache<ReadmeId, String>(
         keyOf: (id) => '${id.kind.name}:${id.name}',
         ttl: kReadmeTtl,
         fetch: (id) => switch (id.kind) {
           ReadmeKind.readme => client.getFullReadme(id.name),
           ReadmeKind.example => client.getExample(id.name),
           ReadmeKind.changelog => client.getChangelog(id.name),
         },
         clock: clock,
         trace: trace,
       ),
       symbolDoc = KeyedCache<SymbolDocId, String>(
         keyOf: (id) => 'symbol_doc:${id.package}:${id.version}:${id.href}',
         ttl: kSymbolDocTtl,
         fetch: (id) => client.getSymbolDoc(id.package, id.href, version: id.version),
         clock: clock,
         trace: trace,
       ),
       meta = KeyedCache<MetaId, String>(
         keyOf: (id) => switch (id) {
           MetaId.scoring => 'meta:scoring',
           MetaId.sdkVersions => 'meta:sdk-versions',
         },
         ttl: kMetaResourcesTtl,
         fetch: (id) => switch (id) {
           MetaId.scoring => Future.value(const PubDevSuccess(kScoringContent)),
           MetaId.sdkVersions => _fetchSdkVersions(metaHttpClient),
         },
         clock: clock,
         trace: trace,
       );

  final http.Client _metaHttpClient;

  /// Whether [_metaHttpClient] was created internally and must be closed by
  /// [dispose].
  final bool _metaHttpOwned;

  final SdkClient _sdkClient;

  /// Whether [_sdkClient] was created internally and must be closed by
  /// [dispose].
  final bool _sdkClientOwned;

  /// Resolves [PackageDetail] by `(name, version)`.
  ///
  /// Shared by `get_package` and `compare_packages`, so the same package's
  /// metadata is fetched from pub.dev at most once per [kPackageMetadataTtl]
  /// window, regardless of which tool triggers the fetch.
  final KeyedCache<PackageDetailId, PackageDetail> packageDetail;

  /// Resolves the dartdoc symbol index by `(name, version)`.
  ///
  /// Shared by `browse_api_symbols`, `find_symbols`, `get_api_diff`, and
  /// `get_symbol_documentation`. A [DomainErrors.packageNotFound] failure
  /// folds into a cached empty-list success — a package permanently missing
  /// dartdoc output is itself a stable, cacheable fact — so only a genuine
  /// transient failure passes through uncached.
  final KeyedCache<ApiIndexId, List<DartdocSymbol>> apiIndex;

  /// Resolves an extracted package source-file map by `(name, version)`.
  ///
  /// Shared by `list_package_source_files`, `get_source_slice`,
  /// `get_throw_statements`, and the `pubspec` package resource, so a
  /// package's tarball is downloaded from pub.dev at most once per
  /// [kSourceFileTtl] window regardless of which reader triggers the fetch. A
  /// [DomainErrors.packageNotFound] failure is remapped to a message naming
  /// the requested package.
  final KeyedCache<SourceFilesId, Map<String, String>> sourceFiles;

  /// Resolves a parsed-AST snapshot by the file coordinate (`name`, `version`,
  /// `path`).
  ///
  /// Shared by `get_source_slice` and `get_throw_statements` so the same file
  /// is parsed at most once per [kAstSnapshotTtl] window. The parse never
  /// fails in a cache sense, so the fetch closure always returns
  /// [PubDevSuccess].
  final KeyedCache<AstSnapshotId, ParseStringResult> ast;

  /// Resolves an extracted SDK source-file map by `(cacheName, ref)` — either
  /// `dart_sdk` or `flutter_sdk`.
  ///
  /// Shared by every SDK-source tool handler, mirroring [sourceFiles]'s role
  /// for pub.dev packages.
  final KeyedCache<SourceFilesId, Map<String, String>> sdkSourceFiles;

  /// Resolves a parsed-AST snapshot for SDK source by the file coordinate
  /// (`name`, `version`, `path`), mirroring [ast]'s role for pub.dev packages.
  final KeyedCache<AstSnapshotId, ParseStringResult> sdkAst;

  /// Resolves a search-results page by the full query tuple.
  ///
  /// Written by `search_packages` and read cache-only, via
  /// [KeyedCache.entries], by the server's `{name}` autocomplete.
  final KeyedCache<SearchResultsId, List<PackageSummary>> searchResults;

  /// Resolves a package's full published-version list by `name`.
  ///
  /// Written by `list_package_versions` and read cache-only, via
  /// [KeyedCache.peek], by the server's `{version}` autocomplete.
  final KeyedCache<VersionListId, List<PackageVersion>> versionList;

  /// Resolves a package's full parsed changelog entry list by `name`.
  ///
  /// Single-owner: `get_changelog` is the only reader.
  final KeyedCache<ChangelogEntriesId, List<ChangelogEntry>> changelog;

  /// Resolves a raw markdown resource body by `(name, kind)`.
  ///
  /// Single-owner: `PackageResourcesHandler` is the only reader, serving the
  /// `readme`, `example`, and `changelog` package resources from one facade.
  final KeyedCache<ReadmeId, String> readme;

  /// Resolves an individual dartdoc symbol documentation page by
  /// `(package, version, href)`.
  ///
  /// Single-owner: `get_symbol_documentation` is the only reader.
  final KeyedCache<SymbolDocId, String> symbolDoc;

  /// Resolves a `pub://meta/` resource body by its fixed [MetaId].
  ///
  /// Single-owner: `MetaResourcesHandler` is the only reader, for the
  /// `scoring` and `sdk-versions` meta resources.
  final KeyedCache<MetaId, String> meta;

  /// Closes the `meta` facade's HTTP client and [_sdkClient] if either was
  /// created internally (no `metaHttpClient`/`sdkClient` was supplied at
  /// construction).
  ///
  /// Call when the registry is no longer needed — e.g. from
  /// `PubMcpServer.shutdown` — so a server that never received an explicit
  /// `metaHttpClient`/`sdkClient` still closes the connections it opened.
  void dispose() {
    if (_metaHttpOwned) _metaHttpClient.close();
    if (_sdkClientOwned) _sdkClient.close();
  }
}

// ─── sdkSourceFiles: Dart SDK path normalization ──────────────────────────────

/// Normalizes a `dart-lang/sdk` repo-relative source-file map to the
/// installed-style shape `get_sdk_source_slice` addresses: strips the raw
/// tarball's `sdk/` top-level prefix (`sdk/lib/core/list.dart` →
/// `lib/core/list.dart`) and drops every entry outside that subtree (`tests/`,
/// `docs/`, `tools/`, …) — content an installed Dart SDK never contains, so
/// it is never a valid `get_sdk_source_slice` lookup target. See ADR 0006.
Map<String, String> _stripDartSdkRepoPrefix(Map<String, String> files) {
  const prefix = 'sdk/';
  final stripped = <String, String>{};
  for (final entry in files.entries) {
    if (!entry.key.startsWith(prefix)) continue;
    stripped[entry.key.substring(prefix.length)] = entry.value;
  }
  return stripped;
}

// ─── meta: SDK-versions fetch ────────────────────────────────────────────────

/// Dart SDK stable VERSION endpoint (returns `{ version, date, revision }`).
const _kDartVersionUrl =
    'https://storage.googleapis.com/dart-archive/channels/stable/release/latest/VERSION';

/// Flutter SDK releases endpoint for Linux.
///
/// Top-level `current_release.stable` holds the hash of the latest stable
/// release; resolve it against `releases` to obtain the version string.
const _kFlutterReleasesUrl =
    'https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json';

/// Request timeout for each individual HTTP call made by the `meta` facade's
/// `sdkVersions` fetch.
const _kMetaRequestTimeout = Duration(seconds: 15);

/// Fetches the current stable Dart and Flutter SDK versions from Google
/// Storage via [httpClient].
///
/// Issues both GET requests concurrently and waits for both to complete.
/// Parses `version` from the Dart VERSION JSON and resolves
/// `current_release.stable` against the Flutter releases array to obtain the
/// Flutter version string. Returns a [PubDevSuccess] wrapping the JSON-encoded
/// `{ dart, flutter }` object, or a [PubDevFailure] carrying a
/// [DomainErrors.unexpectedResponse] error when either endpoint fails or the
/// payload cannot be parsed.
Future<PubDevResult<String>> _fetchSdkVersions(http.Client httpClient) async {
  try {
    final (dartResponse, flutterResponse) = await (
      httpClient.get(Uri.parse(_kDartVersionUrl)).timeout(_kMetaRequestTimeout),
      httpClient.get(Uri.parse(_kFlutterReleasesUrl)).timeout(_kMetaRequestTimeout),
    ).wait;

    if (dartResponse.statusCode != 200) {
      throw Exception('Dart VERSION endpoint returned HTTP ${dartResponse.statusCode}.');
    }
    if (flutterResponse.statusCode != 200) {
      throw Exception('Flutter releases endpoint returned HTTP ${flutterResponse.statusCode}.');
    }

    final dartData = jsonDecode(dartResponse.body) as Map<String, Object?>;
    final dartVersionObject = dartData['version'];
    if (dartVersionObject is! String) {
      throw Exception('Dart VERSION payload is missing a valid version string.');
    }

    final flutterData = jsonDecode(flutterResponse.body) as Map<String, Object?>;
    final currentReleaseObject = flutterData['current_release'];
    if (currentReleaseObject is! Map<String, Object?>) {
      throw Exception('Flutter releases payload is missing current_release data.');
    }
    final stableHashObject = currentReleaseObject['stable'];
    if (stableHashObject is! String) {
      throw Exception('Flutter releases payload is missing current_release.stable hash.');
    }

    final releasesObject = flutterData['releases'];
    if (releasesObject is! List<Object?>) {
      throw Exception('Flutter releases payload is missing releases list.');
    }
    final releases = releasesObject.whereType<Map<String, Object?>>().toList();
    final stableHash = stableHashObject;
    final stableRelease = releases.firstWhere(
      (r) => r['hash'] == stableHash,
      orElse: () => throw Exception(
        'Flutter stable release with hash $stableHash not found in releases list.',
      ),
    );
    final flutterVersionObject = stableRelease['version'];
    if (flutterVersionObject is! String) {
      throw Exception('Flutter release payload is missing a valid version string.');
    }

    return PubDevSuccess(jsonEncode({'dart': dartVersionObject, 'flutter': flutterVersionObject}));
  } on Object catch (e) {
    return PubDevFailure(
      DomainError(
        code: DomainErrors.unexpectedResponse,
        message: 'Failed to fetch stable SDK versions: $e',
        suggestion: 'Try again later; this depends on external Google Storage endpoints.',
      ),
    );
  }
}
