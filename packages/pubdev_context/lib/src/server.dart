/// The pubdev_context MCP server.
///
/// [PubMcpServer] extends [MCPServer] and mixes in [ToolsSupport],
/// [ResourcesSupport], [PromptsSupport], [CompletionsSupport], and
/// [LoggingSupport]. All capabilities are registered inside [PubMcpServer.initialize].
///
/// [PubDevClient], the search [ResponseCache], and the package [ResponseCache]
/// are injected as constructor dependencies. The active log level is set from
/// the [PubMcpConfig] supplied at construction time.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:http/http.dart' as http;

import 'cache/memory_cache.dart';
import 'config/config.dart';
import 'data/models.dart';
import 'data/pub_client.dart';
import 'prompts/prompts.dart';
import 'resources/meta_resources.dart';
import 'resources/package_resources.dart';
import 'tools/browse_api_symbols.dart';
import 'tools/compare_packages.dart';
import 'tools/get_changelog.dart';
import 'tools/get_method_body.dart';
import 'tools/get_package.dart';
import 'tools/get_package_source_file.dart';
import 'tools/get_symbol_documentation.dart';
import 'tools/list_package_source_files.dart';
import 'tools/search_packages.dart';
import 'tools/tool_definitions.dart';
import 'version.dart';

/// MCP server that exposes pub.dev package intelligence to LLM agents.
///
/// Wire it to a channel via the constructor and await [initialized] before
/// sending requests. Use [PubMcpConfig] to control log verbosity. All tools,
/// resources, prompts, and completions are registered inside [initialize].
base class PubMcpServer extends MCPServer
    with ToolsSupport, ResourcesSupport, PromptsSupport, CompletionsSupport, LoggingSupport {
  /// Creates a [PubMcpServer] connected to [channel].
  ///
  /// [config] controls the initial log level and other server-wide settings.
  /// [client] is the pub.dev HTTP gateway. [searchCache] is the shared TTL
  /// store for search results, [packageCache] for individual package lookups
  /// (shared by `get_package` and `compare_packages`), [changelogCache] for
  /// parsed changelog entry lists, [changelogRawCache] for raw changelog
  /// markdown text served by the `pub://package/{name}/changelog` resource,
  /// [apiIndexCache] for dartdoc symbol indexes (shared by `browse_api_symbols`
  /// and the package resource handler), [readmeCache] for full package README
  /// strings, [symbolDocCache] for individual symbol documentation pages, and
  /// [metaCache] for the `pub://meta/` resource responses; callers own their
  /// lifecycles. An optional [metaHttpClient] may be supplied to override the
  /// HTTP client used by the meta resource handler (useful in tests).
  PubMcpServer(
    super.channel, {
    required PubMcpConfig config,
    required PubDevClient client,
    required ResponseCache<List<PackageSummary>> searchCache,
    required ResponseCache<PackageDetail> packageCache,
    required ResponseCache<List<ChangelogEntry>> changelogCache,
    required ResponseCache<String> changelogRawCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
    required ResponseCache<String> readmeCache,
    required ResponseCache<String> symbolDocCache,
    required ResponseCache<Map<String, String>> sourceFilesCache,
    required ResponseCache<String> metaCache,
    http.Client? metaHttpClient,
  }) : _client = client,
       _searchCache = searchCache,
       _packageCache = packageCache,
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
           name: 'pubdev_context',
           version: packageVersion,
         ),
         instructions: kServerInstructions,
       ) {
    loggingLevel = _toLoggingLevel(config.logLevel);
  }

  final PubDevClient _client;
  final ResponseCache<List<PackageSummary>> _searchCache;
  final ResponseCache<PackageDetail> _packageCache;
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
    _registerPrompts();
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
  /// For the `{name}` parameter of [PackageResourcesHandler.kReadmeTemplate],
  /// [PackageResourcesHandler.kExampleTemplate], and [PackageResourcesHandler.kApiTemplate],
  /// returns matching package names from the most recently cached
  /// `search_packages` results. No HTTP call is issued during autocomplete —
  /// cached entries only.
  ///
  /// Returns an empty [Completion] for all other references or argument names.
  @override
  FutureOr<CompleteResult> handleComplete(CompleteRequest request) async {
    final ref = request.ref;
    if (!ref.isResource) {
      return CompleteResult(completion: Completion(values: const []));
    }

    final resourceRef = ref as ResourceTemplateReference;
    final isPackageTemplate =
        resourceRef.uri == PackageResourcesHandler.kReadmeTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kExampleTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kChangelogTemplate.uriTemplate ||
        resourceRef.uri == PackageResourcesHandler.kApiTemplate.uriTemplate;

    if (!isPackageTemplate || request.argument.name != 'name') {
      return CompleteResult(completion: Completion(values: const []));
    }

    final partial = request.argument.value.toLowerCase();
    final names = <String>{};

    // Collect package names from every cached search result — no HTTP calls.
    for (final future in _searchCache.entries.values) {
      final results = await future;
      names.addAll(results.map((s) => s.name));
    }

    final matches = names.where((n) => n.toLowerCase().startsWith(partial)).take(100).toList()
      ..sort();

    return CompleteResult(
      completion: Completion(values: matches, hasMore: false),
    );
  }

  void _registerTools() {
    final searchHandler = SearchPackagesHandler(
      client: _client,
      cache: _searchCache,
      log: log,
    );
    registerTool(searchPackagesTool, searchHandler.call);
    log(LoggingLevel.debug, 'registered tool: search_packages');

    final getPackageHandler = GetPackageHandler(
      client: _client,
      cache: _packageCache,
      log: log,
    );
    registerTool(getPackageTool, getPackageHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_package');

    final getChangelogHandler = GetChangelogHandler(
      client: _client,
      cache: _changelogCache,
      log: log,
    );
    registerTool(getChangelogTool, getChangelogHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_changelog');

    final comparePackagesHandler = ComparePackagesHandler(
      client: _client,
      cache: _packageCache,
      log: log,
    );
    registerTool(comparePackagesTool, comparePackagesHandler.call);
    log(LoggingLevel.debug, 'registered tool: compare_packages');

    final browseApiSymbolsHandler = BrowseApiSymbolsHandler(
      client: _client,
      cache: _apiIndexCache,
      log: log,
    );
    registerTool(browseApiSymbolsTool, browseApiSymbolsHandler.call);
    log(LoggingLevel.debug, 'registered tool: browse_api_symbols');

    final getSymbolDocHandler = GetSymbolDocumentationHandler(
      client: _client,
      cache: _symbolDocCache,
      apiIndexCache: _apiIndexCache,
      log: log,
    );
    registerTool(getSymbolDocumentationTool, getSymbolDocHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_symbol_documentation');

    final getSourceFileHandler = GetPackageSourceFileHandler(
      client: _client,
      cache: _sourceFilesCache,
      log: log,
    );
    registerTool(getPackageSourceFileTool, getSourceFileHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_package_source_file');

    final listSourceFilesHandler = ListPackageSourceFilesHandler(
      client: _client,
      cache: _sourceFilesCache,
      log: log,
    );
    registerTool(listPackageSourceFilesTool, listSourceFilesHandler.call);
    log(LoggingLevel.debug, 'registered tool: list_package_source_files');

    final getMethodBodyHandler = GetMethodBodyHandler(
      client: _client,
      sourceFilesCache: _sourceFilesCache,
      apiIndexCache: _apiIndexCache,
      log: log,
    );
    registerTool(getMethodBodyTool, getMethodBodyHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_method_body');
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

    final handler = PackageResourcesHandler(
      client: _client,
      readmeCache: _readmeCache,
      changelogCache: _changelogRawCache,
      apiIndexCache: _apiIndexCache,
      log: log,
    );
    addResourceTemplate(PackageResourcesHandler.kReadmeTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kReadmeUriTemplate');

    addResourceTemplate(PackageResourcesHandler.kExampleTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kExampleUriTemplate');

    addResourceTemplate(PackageResourcesHandler.kChangelogTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kChangelogUriTemplate');

    addResourceTemplate(PackageResourcesHandler.kApiTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kApiUriTemplate');
  }

  void _registerPrompts() {
    addPrompt(kAddAndSetupPackagePrompt, const AddAndSetupPackageHandler().call);
    log(LoggingLevel.debug, 'registered prompt: add-and-setup-package');

    addPrompt(kAnalyzeUpgradeImpactPrompt, const AnalyzeUpgradeImpactHandler().call);
    log(LoggingLevel.debug, 'registered prompt: analyze-upgrade-impact');

    addPrompt(kEvaluateAlternativesPrompt, const EvaluateAlternativesHandler().call);
    log(LoggingLevel.debug, 'registered prompt: evaluate-alternatives');
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
  ]);

  static LoggingLevel _toLoggingLevel(LogLevel level) => switch (level) {
    LogLevel.debug => LoggingLevel.debug,
    LogLevel.info => LoggingLevel.info,
    LogLevel.warning => LoggingLevel.warning,
    LogLevel.error => LoggingLevel.error,
  };
}
