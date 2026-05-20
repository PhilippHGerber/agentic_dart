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

import 'package:dart_mcp/server.dart';

import 'cache/memory_cache.dart';
import 'config/config.dart';
import 'data/models.dart';
import 'data/pub_client.dart';
import 'tools/compare_packages.dart';
import 'tools/get_changelog.dart';
import 'tools/get_package.dart';
import 'tools/search_api_symbols.dart';
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
  /// parsed changelog entry lists, and [apiIndexCache] for dartdoc symbol
  /// indexes (shared by `search_api_symbols` and the package resource handler);
  /// callers own their lifecycles.
  PubMcpServer(
    super.channel, {
    required PubMcpConfig config,
    required PubDevClient client,
    required ResponseCache<List<PackageSummary>> searchCache,
    required ResponseCache<PackageDetail> packageCache,
    required ResponseCache<List<ChangelogEntry>> changelogCache,
    required ResponseCache<List<DartdocSymbol>> apiIndexCache,
  }) : _client = client,
       _searchCache = searchCache,
       _packageCache = packageCache,
       _changelogCache = changelogCache,
       _apiIndexCache = apiIndexCache,
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
  final ResponseCache<List<DartdocSymbol>> _apiIndexCache;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    log(LoggingLevel.info, 'pubdev_context server initialized');
    return result;
  }

  /// Returns an empty completion result; completions are reserved for a future release.
  @override
  FutureOr<CompleteResult> handleComplete(CompleteRequest request) =>
      CompleteResult(completion: Completion(values: const []));

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

    final searchApiSymbolsHandler = SearchApiSymbolsHandler(
      client: _client,
      cache: _apiIndexCache,
      log: log,
    );
    registerTool(searchApiSymbolsTool, searchApiSymbolsHandler.call);
    log(LoggingLevel.debug, 'registered tool: search_api_symbols');
  }

  static LoggingLevel _toLoggingLevel(LogLevel level) => switch (level) {
    LogLevel.debug => LoggingLevel.debug,
    LogLevel.info => LoggingLevel.info,
    LogLevel.warning => LoggingLevel.warning,
    LogLevel.error => LoggingLevel.error,
  };
}
