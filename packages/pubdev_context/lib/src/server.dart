/// The pubdev_context MCP server.
///
/// [PubMcpServer] extends [MCPServer] and mixes in [ToolsSupport],
/// [ResourcesSupport], [CompletionsSupport], and [LoggingSupport]. All
/// capabilities are registered inside [PubMcpServer.initialize].
///
/// [PubDevClient], the search [ResponseCache], and the package [ResponseCache]
/// are injected as constructor dependencies. The active log level is set from
/// the [PubMcpConfig] supplied at construction time.
library;

import 'dart:async';
import 'dart:convert';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;

import 'cache/memory_cache.dart';
import 'config/config.dart';
import 'data/models.dart';
import 'data/pub_client.dart';
import 'resources/meta_resources.dart';
import 'resources/package_resources.dart';
import 'tools/browse_api_symbols.dart';
import 'tools/compare_packages.dart';
import 'tools/find_symbols.dart';
import 'tools/get_api_diff.dart';
import 'tools/get_changelog.dart';
import 'tools/get_package.dart';
import 'tools/get_source_slice.dart';
import 'tools/get_symbol_documentation.dart';
import 'tools/get_throw_statements.dart';
import 'tools/list_package_source_files.dart';
import 'tools/list_package_versions.dart';
import 'tools/search_packages.dart';
import 'tools/tool_definitions.dart';
import 'trace/llm_boundary.dart';
import 'trace/wire_trace.dart';
import 'version.dart';

/// MCP server that exposes pub.dev package intelligence to LLM agents.
///
/// Wire it to a channel via the constructor and await [initialized] before
/// sending requests. Use [PubMcpConfig] to control log verbosity. All tools,
/// resources, and completions are registered inside [initialize].
base class PubMcpServer extends MCPServer
    with ToolsSupport, ResourcesSupport, CompletionsSupport, LoggingSupport {
  /// Creates a [PubMcpServer] connected to [channel].
  ///
  /// [config] controls the initial log level and other server-wide settings.
  /// [client] is the pub.dev HTTP gateway. [searchCache] is the shared TTL
  /// store for search results, [packageCache] for individual package lookups
  /// (shared by `get_package` and `compare_packages`), [changelogCache] for
  /// parsed changelog entry lists, [changelogRawCache] for raw changelog
  /// markdown text served by the `pub://package/{name}@{version}/changelog` resource,
  /// [apiIndexCache] for dartdoc symbol indexes (shared by `browse_api_symbols`
  /// and the package resource handler), [readmeCache] for full package README
  /// strings, [symbolDocCache] for individual symbol documentation pages, and
  /// [metaCache] for the `pub://meta/` resource responses; callers own their
  /// lifecycles. An optional [metaHttpClient] may be supplied to override the
  /// HTTP client used by the meta resource handler (useful in tests).
  ///
  /// When an enabled [trace] is supplied, every tool call and resource-template
  /// read is wrapped by a central LLM-boundary tracer that assigns a Correlation
  /// Id, records the inbound call and outbound result, and runs the handler
  /// inside a [Zone] carrying the id. When [trace] is null or disabled, no
  /// wrapper is installed and tracing costs nothing.
  PubMcpServer(
    super.channel, {
    required PubMcpConfig config,
    required PubDevClient client,
    required ResponseCache<List<PackageSummary>> searchCache,
    required ResponseCache<PackageDetail> packageCache,
    required ResponseCache<List<PackageVersion>> packageVersionsCache,
    required ResponseCache<List<ChangelogEntry>> changelogCache,
    required ResponseCache<String> changelogRawCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required ResponseCache<String> readmeCache,
    required ResponseCache<String> symbolDocCache,
    required ResponseCache<Map<String, String>> sourceFilesCache,
    required ResponseCache<String> metaCache,
    http.Client? metaHttpClient,
    WireTrace? trace,
  }) : _tracer = trace != null && trace.isEnabled
           ? LlmBoundaryTracer(trace)
           : null,
       _trace = trace != null && trace.isEnabled ? trace : null,
       _client = client,
       _searchCache = searchCache,
       _packageCache = packageCache,
       _packageVersionsCache = packageVersionsCache,
       _changelogCache = changelogCache,
       _changelogRawCache = changelogRawCache,
       _apiIndexCache = apiIndexCache,
       _readmeCache = readmeCache,
       _symbolDocCache = symbolDocCache,
       _sourceFilesCache = sourceFilesCache,
       _metaCache = metaCache,
       _metaHttp = metaHttpClient ?? http.Client(),
       _metaHttpOwned = metaHttpClient == null,
       super.fromStreamChannel(
         implementation: Implementation(
           name: 'dart_pubdev',
           version: packageVersion,
         ),
         instructions: kServerInstructions,
       ) {
    loggingLevel = _toLoggingLevel(config.logLevel);
  }

  /// The central LLM-boundary tracer, or `null` when tracing is disabled.
  final LlmBoundaryTracer? _tracer;

  /// The Wire Trace itself, or `null` when tracing is disabled. Retained so the
  /// caches this server owns internally (the shared AST cache) can be traced the
  /// same way as the injected ones.
  final WireTrace? _trace;
  final PubDevClient _client;
  final ResponseCache<List<PackageSummary>> _searchCache;
  final ResponseCache<PackageDetail> _packageCache;
  final ResponseCache<List<PackageVersion>> _packageVersionsCache;
  final ResponseCache<List<ChangelogEntry>> _changelogCache;
  final ResponseCache<String> _changelogRawCache;
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;
  final ResponseCache<String> _readmeCache;
  final ResponseCache<String> _symbolDocCache;
  final ResponseCache<Map<String, String>> _sourceFilesCache;
  final ResponseCache<String> _metaCache;
  final http.Client _metaHttp;

  /// Whether [_metaHttp] was created internally and must be closed on shutdown.
  final bool _metaHttpOwned;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    _registerResources();
    log(LoggingLevel.info, 'pubdev_context server initialized');
    return result;
  }

  @override
  Future<void> shutdown() async {
    if (_metaHttpOwned) _metaHttp.close();
    await super.shutdown();
  }

  /// Handles `completion/complete` requests for resource template parameters.
  ///
  /// The package resource templates ([PackageResourcesHandler.kReadmeTemplate]
  /// and friends) carry two parameters, `{name}` and `{version}`:
  ///
  ///   - For `name`, returns matching package names from the most recently
  ///     cached `search_packages` results.
  ///   - For `version`, returns [kLatestVersionAlias] plus any versions cached
  ///     for the package named in [CompleteRequest.context] (populated by
  ///     `list_package_versions`).
  ///
  /// No HTTP call is issued during autocomplete — cached entries only. Returns
  /// an empty [Completion] for all other references or argument names.
  @override
  FutureOr<CompleteResult> handleComplete(CompleteRequest request) async {
    final ref = request.ref;
    if (!ref.isResource) return _emptyCompletion;

    final resourceRef = ref as ResourceTemplateReference;
    final isPackageTemplate =
        resourceRef.uri == PackageResourcesHandler.kReadmeTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kExampleTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kChangelogTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kApiTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kPubspecTemplate.uriTemplate;
    if (!isPackageTemplate) return _emptyCompletion;

    return switch (request.argument.name) {
      'name' => _completeName(request.argument.value),
      'version' => _completeVersion(request),
      _ => _emptyCompletion,
    };
  }

  static CompleteResult get _emptyCompletion =>
      CompleteResult(completion: Completion(values: const []));

  /// Completes the `{name}` parameter from cached `search_packages` results.
  Future<CompleteResult> _completeName(String value) async {
    final partial = value.toLowerCase();
    final names = <String>{};

    // Collect package names from every cached search result — no HTTP calls.
    for (final future in _searchCache.entries.values) {
      final results = await future;
      names.addAll(results.map((s) => s.name));
    }

    final matches = names.where((n) => n.toLowerCase().startsWith(partial)).take(100).toList()
      ..sort();

    return CompleteResult(completion: Completion(values: matches, hasMore: false));
  }

  /// Completes the `{version}` parameter.
  ///
  /// Always offers [kLatestVersionAlias]; additionally offers concrete versions
  /// cached by `list_package_versions` for the package named in the request
  /// [CompleteRequest.context], preserving the cache's newest-first order.
  Future<CompleteResult> _completeVersion(CompleteRequest request) async {
    final partial = request.argument.value.toLowerCase();

    final candidates = <String>[kLatestVersionAlias];
    final name = request.context?.arguments?['name'];
    if (name != null && name.isNotEmpty) {
      final cached = _packageVersionsCache.get('$kVersionsCachePrefix:$name');
      if (cached != null) {
        candidates.addAll((await cached).map((v) => v.version));
      }
    }

    final matches = <String>{}; // dedupe while preserving insertion order
    for (final v in candidates) {
      if (v.toLowerCase().startsWith(partial)) matches.add(v);
      if (matches.length == 100) break;
    }

    return CompleteResult(
      completion: Completion(values: matches.toList(), hasMore: false),
    );
  }

  /// Registers [tool], wrapping [impl] with the LLM-boundary tracer when tracing
  /// is enabled. When it is not, [impl] is registered unchanged.
  void _registerTracedTool(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) impl,
  ) {
    final tracer = _tracer;
    registerTool(tool, tracer == null ? impl : tracer.wrapTool(impl));
  }

  /// Adds [template], wrapping [handler] with the LLM-boundary tracer when
  /// tracing is enabled. When it is not, [handler] is added unchanged.
  void _addTracedResourceTemplate(
    ResourceTemplate template,
    FutureOr<ReadResourceResult?> Function(ReadResourceRequest) handler,
  ) {
    final tracer = _tracer;
    addResourceTemplate(
      template,
      tracer == null ? handler : tracer.wrapResource(handler),
    );
  }

  void _registerTools() {
    final searchHandler = SearchPackagesHandler(
      client: _client,
      cache: _searchCache,
      log: log,
    );
    _registerTracedTool(searchPackagesTool, searchHandler.call);
    log(LoggingLevel.debug, 'registered tool: search_packages');

    final getPackageHandler = GetPackageHandler(
      client: _client,
      cache: _packageCache,
      log: log,
    );
    _registerTracedTool(getPackageTool, getPackageHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_package');

    final getChangelogHandler = GetChangelogHandler(
      client: _client,
      cache: _changelogCache,
      log: log,
    );
    _registerTracedTool(getChangelogTool, getChangelogHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_changelog');

    final comparePackagesHandler = ComparePackagesHandler(
      client: _client,
      cache: _packageCache,
      log: log,
    );
    _registerTracedTool(comparePackagesTool, comparePackagesHandler.call);
    log(LoggingLevel.debug, 'registered tool: compare_packages');

    final listPackageVersionsHandler = ListPackageVersionsHandler(
      client: _client,
      cache: _packageVersionsCache,
      log: log,
    );
    _registerTracedTool(listPackageVersionsTool, listPackageVersionsHandler.call);
    log(LoggingLevel.debug, 'registered tool: list_package_versions');

    final browseApiSymbolsHandler = BrowseApiSymbolsHandler(
      client: _client,
      cache: _apiIndexCache,
      log: log,
    );
    _registerTracedTool(browseApiSymbolsTool, browseApiSymbolsHandler.call);
    log(LoggingLevel.debug, 'registered tool: browse_api_symbols');

    final findSymbolsHandler = FindSymbolsHandler(
      client: _client,
      cache: _apiIndexCache,
      log: log,
    );
    _registerTracedTool(findSymbolsTool, findSymbolsHandler.call);
    log(LoggingLevel.debug, 'registered tool: find_symbols');

    final getApiDiffHandler = GetApiDiffHandler(
      client: _client,
      cache: _apiIndexCache,
      log: log,
    );
    _registerTracedTool(getApiDiffTool, getApiDiffHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_api_diff');

    final getSymbolDocHandler = GetSymbolDocumentationHandler(
      client: _client,
      cache: _symbolDocCache,
      apiIndexCache: _apiIndexCache,
      log: log,
    );
    _registerTracedTool(getSymbolDocumentationTool, getSymbolDocHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_symbol_documentation');

    final listSourceFilesHandler = ListPackageSourceFilesHandler(
      client: _client,
      cache: _sourceFilesCache,
      log: log,
    );
    _registerTracedTool(listPackageSourceFilesTool, listSourceFilesHandler.call);
    log(LoggingLevel.debug, 'registered tool: list_package_source_files');

    // Shared AST snapshot cache — reused by get_source_slice and get_throw_statements
    // so the same source file is never parsed twice in a single agent turn.
    final sharedAstCache = ResponseCache<ParseStringResult>(trace: _trace);

    final getSourceSliceHandler = GetSourceSliceHandler(
      client: _client,
      sourceFilesCache: _sourceFilesCache,
      log: log,
      astCache: sharedAstCache,
    );
    _registerTracedTool(getSourceSliceTool, getSourceSliceHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_source_slice');

    final getThrowStatementsHandler = GetThrowStatementsHandler(
      client: _client,
      sourceFilesCache: _sourceFilesCache,
      apiIndexCache: _apiIndexCache,
      log: log,
      astCache: sharedAstCache,
    );
    _registerTracedTool(getThrowStatementsTool, getThrowStatementsHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_throw_statements');
  }

  void _registerResources() {
    final metaHandler = MetaResourcesHandler(
      httpClient: _metaHttp,
      cache: _metaCache,
      log: log,
      resourcesManifest: _buildResourcesManifest(),
    );
    addResource(kScoringResource, metaHandler.handleScoring);
    log(LoggingLevel.debug, 'registered resource: pub://meta/scoring');
    addResource(kSdkVersionsResource, metaHandler.handleSdkVersions);
    log(LoggingLevel.debug, 'registered resource: pub://meta/sdk-versions');
    addResource(kResourcesResource, metaHandler.handleResources);
    log(LoggingLevel.debug, 'registered resource: pub://meta/resources');
    addResource(kInstructionsResource, metaHandler.handleInstructions);
    log(LoggingLevel.debug, 'registered resource: pub://meta/instructions');

    final handler = PackageResourcesHandler(
      client: _client,
      readmeCache: _readmeCache,
      changelogCache: _changelogRawCache,
      apiIndexCache: _apiIndexCache,
      sourceFilesCache: _sourceFilesCache,
      log: log,
    );
    _addTracedResourceTemplate(PackageResourcesHandler.kReadmeTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kReadmeUriTemplate');

    _addTracedResourceTemplate(PackageResourcesHandler.kExampleTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kExampleUriTemplate');

    _addTracedResourceTemplate(PackageResourcesHandler.kChangelogTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kChangelogUriTemplate');

    _addTracedResourceTemplate(PackageResourcesHandler.kApiTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kApiUriTemplate');

    _addTracedResourceTemplate(PackageResourcesHandler.kPubspecTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kPubspecUriTemplate');
  }

  static String _buildResourcesManifest() => jsonEncode([
    {
      'uri': kScoringResource.uri,
      'mimeType': kScoringResource.mimeType,
      'description': kScoringResource.description,
    },
    {
      'uri': kSdkVersionsResource.uri,
      'mimeType': kSdkVersionsResource.mimeType,
      'description': kSdkVersionsResource.description,
    },
    {
      'uri': kResourcesResource.uri,
      'mimeType': kResourcesResource.mimeType,
      'description': kResourcesResource.description,
    },
    {
      'uri': kInstructionsResource.uri,
      'mimeType': kInstructionsResource.mimeType,
      'description': kInstructionsResource.description,
    },
    {
      'uri': PackageResourcesHandler.kReadmeTemplate.uriTemplate,
      'mimeType': PackageResourcesHandler.kReadmeTemplate.mimeType,
      'description': PackageResourcesHandler.kReadmeTemplate.description,
    },
    {
      'uri': PackageResourcesHandler.kExampleTemplate.uriTemplate,
      'mimeType': PackageResourcesHandler.kExampleTemplate.mimeType,
      'description': PackageResourcesHandler.kExampleTemplate.description,
    },
    {
      'uri': PackageResourcesHandler.kChangelogTemplate.uriTemplate,
      'mimeType': PackageResourcesHandler.kChangelogTemplate.mimeType,
      'description': PackageResourcesHandler.kChangelogTemplate.description,
    },
    {
      'uri': PackageResourcesHandler.kApiTemplate.uriTemplate,
      'mimeType': PackageResourcesHandler.kApiTemplate.mimeType,
      'description': PackageResourcesHandler.kApiTemplate.description,
    },
    {
      'uri': PackageResourcesHandler.kPubspecTemplate.uriTemplate,
      'mimeType': PackageResourcesHandler.kPubspecTemplate.mimeType,
      'description': PackageResourcesHandler.kPubspecTemplate.description,
    },
  ]);

  static LoggingLevel _toLoggingLevel(LogLevel level) => switch (level) {
    LogLevel.debug => LoggingLevel.debug,
    LogLevel.info => LoggingLevel.info,
    LogLevel.warning => LoggingLevel.warning,
    LogLevel.error => LoggingLevel.error,
  };
}
