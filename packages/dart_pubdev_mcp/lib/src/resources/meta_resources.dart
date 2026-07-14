/// Resource handlers for the `pub://meta/` namespace.
///
/// Serves these resources via [ResourcesSupport.addResource]:
///   - `pub://meta/scoring`      — plain-text explanation of the pub.dev
///     160-point scoring system; content is embedded at compile time.
///   - `pub://meta/sdk-versions` — current stable Dart and Flutter SDK
///     versions fetched from Google Storage and returned as JSON.
///   - `pub://meta/instructions` — the compile-time [kServerInstructions]
///     handshake manual, re-exposed as a read-only resource so a human or
///     meta-agent can prompt the LLM to re-read it.
///
/// The scoring and SDK-versions resources are resolved through the shared
/// `meta` [KeyedCache] facade (from `CacheRegistry`), cached with a 24-hour
/// TTL. The instructions resource is served straight from the compile-time
/// constant with no HTTP call or caching.
/// See issue #10 and issue #11.
library;

import 'package:dart_mcp/server.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';
import '../tools/tool_definitions.dart' show kServerInstructions;
import 'scoring_content.dart';

export 'scoring_content.dart' show kScoringContent;

// ─── URIs ─────────────────────────────────────────────────────────────────────

/// URI for the pub.dev scoring explanation resource.
const _kScoringUri = 'pub://meta/scoring';

/// URI for the current stable SDK versions resource.
const _kSdkVersionsUri = 'pub://meta/sdk-versions';

/// URI for the resource manifest resource.
const _kResourcesUri = 'pub://meta/resources';

/// URI for the server instructions resource.
const _kInstructionsUri = 'pub://meta/instructions';

// ─── Resource descriptors ─────────────────────────────────────────────────────

/// [Resource] descriptor for `pub://meta/scoring`.
final kScoringResource = Resource(
  uri: _kScoringUri,
  name: 'pub.dev scoring guide',
  description:
      'Read this when the user asks how pub.dev scores packages, or when you need to explain a low score. '
      'It covers the 160-point breakdown: conventions, documentation, platform support, static analysis, and dependency freshness.',
  mimeType: 'text/plain',
);

/// [Resource] descriptor for `pub://meta/sdk-versions`.
final kSdkVersionsResource = Resource(
  uri: _kSdkVersionsUri,
  name: 'Stable SDK versions',
  description:
      'Read this when you need the current stable Dart or Flutter SDK version — '
      'for example when validating SDK constraints in pubspec.yaml. '
      'Returns JSON: { "dart": "<version>", "flutter": "<version>" }.',
  mimeType: 'application/json',
);

/// [Resource] descriptor for `pub://meta/resources`.
final kResourcesResource = Resource(
  uri: _kResourcesUri,
  name: 'Resource manifest',
  description:
      'Read this first to discover all resource URIs available on this server. '
      'Returns a JSON array; each entry has uri, mimeType, and description.',
  mimeType: 'application/json',
);

/// [Resource] descriptor for `pub://meta/instructions`.
final kInstructionsResource = Resource(
  uri: _kInstructionsUri,
  name: 'Server instructions',
  description:
      'Read this to re-read the server manual — the same instructions delivered '
      'during the MCP handshake. Use it when a workflow feels off or you have '
      'lost track of which tools and resources this server exposes.',
  mimeType: 'text/plain',
);

// ─── MetaResourcesHandler ─────────────────────────────────────────────────────

/// Resource handler for the `pub://meta/` namespace.
///
/// Register the two meta resources on a [ResourcesSupport] server by passing
/// [handleScoring] and [handleSdkVersions] as the `impl` argument to
/// [ResourcesSupport.addResource]:
///
/// ```dart
/// final meta = MetaResourcesHandler(meta: registry.meta, log: log, resourcesManifest: manifest);
/// addResource(kScoringResource, meta.handleScoring);
/// addResource(kSdkVersionsResource, meta.handleSdkVersions);
/// ```
///
/// Both [handleScoring] and [handleSdkVersions] resolve through the shared
/// `meta` [KeyedCache] facade (from `CacheRegistry`), which owns the HTTP
/// client used for the two Google Storage SDK-version endpoints — a boundary
/// kept separate from the `PubDevClient` used elsewhere in the server.
final class MetaResourcesHandler {
  /// Creates a [MetaResourcesHandler].
  ///
  /// [meta] is the shared [KeyedCache] facade (from `CacheRegistry`) that
  /// resolves and caches both meta resource bodies by [MetaId].
  const MetaResourcesHandler({
    required KeyedCache<MetaId, String> meta,
    required String resourcesManifest,
  }) : _meta = meta,
       _resourcesManifest = resourcesManifest;

  final KeyedCache<MetaId, String> _meta;
  final String _resourcesManifest;

  // ── Handlers ──────────────────────────────────────────────────────────────

  /// Handles a [ReadResourceRequest] for `pub://meta/resources`.
  ///
  /// Returns the pre-built manifest JSON passed in at construction time.
  /// The manifest is derived from the resource and template descriptors in
  /// the server layer and never makes an HTTP call.
  Future<ReadResourceResult> handleResources(ReadResourceRequest request) async =>
      _textResult(request.uri, _resourcesManifest, 'application/json');

  /// Handles a [ReadResourceRequest] for `pub://meta/instructions`.
  ///
  /// Returns the compile-time constant [kServerInstructions] verbatim with MIME
  /// type `text/plain`. This is the identical content passed in the MCP
  /// handshake `instructions` field — one constant, two delivery paths. No HTTP
  /// call is made and no caching is performed.
  Future<ReadResourceResult> handleInstructions(ReadResourceRequest request) async =>
      _textResult(request.uri, kServerInstructions, 'text/plain');

  /// Handles a [ReadResourceRequest] for `pub://meta/scoring`.
  ///
  /// Returns the compile-time constant [kScoringContent] with MIME type
  /// `text/plain`. No HTTP call is ever made — `meta`'s fetch closure for
  /// [MetaId.scoring] always succeeds with the constant.
  Future<ReadResourceResult> handleScoring(ReadResourceRequest request) async {
    final result = await _meta.resolve(MetaId.scoring);
    return switch (result) {
      PubDevSuccess(:final value) => _textResult(request.uri, value, 'text/plain'),
      // The scoring fetch closure never fails — see CacheRegistry.meta.
      PubDevFailure(:final error) => throw StateError('unexpected scoring fetch failure: $error'),
    };
  }

  /// Handles a [ReadResourceRequest] for `pub://meta/sdk-versions`.
  ///
  /// Resolves through `meta` for [MetaId.sdkVersions], returning a JSON object
  /// `{ "dart": "<version>", "flutter": "<version>" }` with MIME type
  /// `application/json`.
  ///
  /// Throws [Exception] if either Google Storage endpoint returns a non-200
  /// status, the response cannot be parsed, or the stable Flutter release hash
  /// is absent from the releases list.
  Future<ReadResourceResult> handleSdkVersions(ReadResourceRequest request) async {
    final result = await _meta.resolve(MetaId.sdkVersions);
    return switch (result) {
      PubDevSuccess(:final value) => _textResult(request.uri, value, 'application/json'),
      PubDevFailure(:final error) => throw Exception(error.message),
    };
  }

  static ReadResourceResult _textResult(String uri, String text, String mimeType) =>
      ReadResourceResult(
        contents: [TextResourceContents(uri: uri, text: text, mimeType: mimeType)],
      );
}
