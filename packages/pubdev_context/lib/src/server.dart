/// The pubdev_context MCP server.
///
/// [PubMcpServer] extends [MCPServer] and mixes in [ToolsSupport],
/// [ResourcesSupport], [PromptsSupport], [CompletionsSupport], and
/// [LoggingSupport]. All capabilities are registered inside [PubMcpServer.initialize].
///
/// [PubDevClient] and the search [ResponseCache] are injected as constructor
/// dependencies. The active log level is set from the [PubMcpConfig] supplied
/// at construction time.
library;

import 'dart:async';

import 'package:dart_mcp/server.dart';

import 'cache/memory_cache.dart';
import 'config/config.dart';
import 'data/models.dart';
import 'data/pub_client.dart';
import 'tools/search_packages.dart';

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
  /// store for search results; callers own its lifecycle.
  PubMcpServer(
    super.channel, {
    required PubMcpConfig config,
    required PubDevClient client,
    required ResponseCache<List<PackageSummary>> searchCache,
  }) : _client = client,
       _searchCache = searchCache,
       super.fromStreamChannel(
         implementation: Implementation(
           name: 'pubdev_context',
           version: '0.1.0',
         ),
         instructions:
             'Search, evaluate, and inspect Dart and Flutter packages on pub.dev. '
             'Use search_packages to discover packages by keyword. '
             'All errors carry a machine-readable code and a corrective suggestion.',
       ) {
    loggingLevel = _toLoggingLevel(config.logLevel);
  }

  final PubDevClient _client;
  final ResponseCache<List<PackageSummary>> _searchCache;

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
    final handler = SearchPackagesHandler(
      client: _client,
      cache: _searchCache,
      log: log,
    );
    registerTool(searchPackagesTool, handler.call);
    log(LoggingLevel.debug, 'registered tool: search_packages');
  }

  static LoggingLevel _toLoggingLevel(LogLevel level) => switch (level) {
    LogLevel.debug => LoggingLevel.debug,
    LogLevel.info => LoggingLevel.info,
    LogLevel.warning => LoggingLevel.warning,
    LogLevel.error => LoggingLevel.error,
  };
}
