/// The pubdev_context MCP server.
///
/// [PubMcpServer] extends [MCPServer] and mixes in [ToolsSupport],
/// [ResourcesSupport], [CompletionsSupport], and [LoggingSupport]. All
/// capabilities are registered inside [PubMcpServer.initialize].
///
/// [PubDevClient] and the [CacheRegistry] are injected as constructor
/// dependencies. The active log level is set from the [PubMcpConfig] supplied
/// at construction time.
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import 'analysis/ast_access.dart';
import 'cache/cache_registry.dart';
import 'config/config.dart';
import 'data/domain_error.dart';
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
import 'tools/tool_response.dart';
import 'tools/version_resolver.dart';
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
  /// [client] is the pub.dev HTTP gateway. [cacheRegistry] constructs and owns
  /// every handler-layer `KeyedCache` facade — `packageDetail` (shared by
  /// `get_package` and `compare_packages`), `apiIndex` (shared by
  /// `browse_api_symbols`, `find_symbols`, `get_api_diff`, the symbol-
  /// documentation handler, `get_throw_statements`, and the package resource
  /// handler's `api` resource), `sourceFiles` (shared by
  /// `list_package_source_files`, `get_source_slice`, `get_throw_statements`,
  /// and the `pubspec` package resource), `ast` (shared by `get_source_slice`
  /// and `get_throw_statements`), `searchResults` (shared by `search_packages`
  /// and the `{name}` autocomplete handler), `versionList` (shared by
  /// `list_package_versions` and the `{version}` autocomplete handler),
  /// `changelog` (`get_changelog`), `readme` (the package resource handler's
  /// `readme`, `example`, and `changelog` resources), `symbolDoc` (the
  /// symbol-documentation handler), and `meta` (the `pub://meta/` resource
  /// handler). This is the server's sole cache dependency — every
  /// handler-layer store flows through the registry.
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
    required CacheRegistry cacheRegistry,
    WireTrace? trace,
  }) : _tracer = trace != null && trace.isEnabled ? LlmBoundaryTracer(trace) : null,
       _client = client,
       _cacheRegistry = cacheRegistry,
       super.fromStreamChannel(
         implementation: Implementation(
           name: 'dart_pubdev',
           version: packageVersion,
         ),
         instructions: kServerInstructions,
       ) {
    loggingLevel = _toLoggingLevel(config.logLevel);
    _versionResolver = VersionResolver(client: client, log: log);
    _astAccess = AstAccess(sourceFiles: cacheRegistry.sourceFiles, ast: cacheRegistry.ast);
  }

  /// The central LLM-boundary tracer, or `null` when tracing is disabled.
  final LlmBoundaryTracer? _tracer;
  final PubDevClient _client;
  final CacheRegistry _cacheRegistry;

  /// Resolves the Resolved Version for the 9 version-accepting tools that
  /// delegate to it; constructed once alongside [_cacheRegistry].
  late final VersionResolver _versionResolver;

  /// Resolves source files and parsed ASTs for `get_source_slice` and
  /// `get_throw_statements`; constructed once alongside [_cacheRegistry] so
  /// both handlers share the same `sourceFiles`/`ast` cache entries.
  late final AstAccess _astAccess;

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
    _cacheRegistry.dispose();
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
    for (final future in _cacheRegistry.searchResults.entries.values) {
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
      final cached = _cacheRegistry.versionList.peek((name: name));
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

  /// Registers [tool], wrapping [impl] with the ADR-0006 argument-validation
  /// wrapper and, when tracing is enabled, the LLM-boundary tracer.
  ///
  /// Ordering is tracer outermost, validation inside it, handler innermost —
  /// so a schema-rejected call still appears in the Wire Trace with a
  /// Correlation Id. [registerTool] is called with `validateArguments: false`:
  /// `dart_mcp`'s own schema validation is disabled for every tool, since it
  /// would reject violations as plain text and bypass the ADR-0002 envelope
  /// [_validated] provides instead.
  void _registerTracedTool(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) impl,
  ) {
    final validated = _validated(tool, impl);
    final tracer = _tracer;
    registerTool(
      tool,
      tracer == null ? validated : tracer.wrapTool(validated),
      validateArguments: false,
    );
  }

  /// Wraps [impl] so a call's arguments are validated against [tool]'s input
  /// schema before the handler runs (ADR-0006).
  ///
  /// A schema violation short-circuits to an ADR-0002 `INVALID_ARGUMENT` Tool
  /// Error built via [ToolResponse.error], joining every [ValidationError]
  /// into the error message. A valid call reaches [impl] unchanged.
  static FutureOr<CallToolResult> Function(CallToolRequest) _validated(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) impl,
  ) {
    return (request) {
      final errors = tool.inputSchema.validate(request.arguments ?? const <String, Object?>{});
      if (errors.isEmpty) return impl(request);
      return ToolResponse.error(
        DomainError(
          code: DomainErrors.invalidArgument,
          message: errors.map((e) => e.toErrorString()).join('; '),
          suggestion: "Check the arguments against the '${tool.name}' tool's input schema.",
        ),
      );
    };
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
      searchResults: _cacheRegistry.searchResults,
      log: log,
    );
    _registerTracedTool(searchPackagesTool, searchHandler.call);
    log(LoggingLevel.debug, 'registered tool: search_packages');

    final getPackageHandler = GetPackageHandler(
      versionResolver: _versionResolver,
      packageDetail: _cacheRegistry.packageDetail,
      log: log,
    );
    _registerTracedTool(getPackageTool, getPackageHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_package');

    final getChangelogHandler = GetChangelogHandler(
      versionResolver: _versionResolver,
      changelog: _cacheRegistry.changelog,
      log: log,
    );
    _registerTracedTool(getChangelogTool, getChangelogHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_changelog');

    final comparePackagesHandler = ComparePackagesHandler(
      versionResolver: _versionResolver,
      packageDetail: _cacheRegistry.packageDetail,
      log: log,
    );
    _registerTracedTool(comparePackagesTool, comparePackagesHandler.call);
    log(LoggingLevel.debug, 'registered tool: compare_packages');

    final listPackageVersionsHandler = ListPackageVersionsHandler(
      versionList: _cacheRegistry.versionList,
      log: log,
    );
    _registerTracedTool(listPackageVersionsTool, listPackageVersionsHandler.call);
    log(LoggingLevel.debug, 'registered tool: list_package_versions');

    final browseApiSymbolsHandler = BrowseApiSymbolsHandler(
      versionResolver: _versionResolver,
      apiIndex: _cacheRegistry.apiIndex,
      log: log,
    );
    _registerTracedTool(browseApiSymbolsTool, browseApiSymbolsHandler.call);
    log(LoggingLevel.debug, 'registered tool: browse_api_symbols');

    final findSymbolsHandler = FindSymbolsHandler(
      versionResolver: _versionResolver,
      apiIndex: _cacheRegistry.apiIndex,
      log: log,
    );
    _registerTracedTool(findSymbolsTool, findSymbolsHandler.call);
    log(LoggingLevel.debug, 'registered tool: find_symbols');

    final getApiDiffHandler = GetApiDiffHandler(
      apiIndex: _cacheRegistry.apiIndex,
      log: log,
    );
    _registerTracedTool(getApiDiffTool, getApiDiffHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_api_diff');

    final getSymbolDocHandler = GetSymbolDocumentationHandler(
      versionResolver: _versionResolver,
      apiIndex: _cacheRegistry.apiIndex,
      symbolDoc: _cacheRegistry.symbolDoc,
      log: log,
    );
    _registerTracedTool(getSymbolDocumentationTool, getSymbolDocHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_symbol_documentation');

    final listSourceFilesHandler = ListPackageSourceFilesHandler(
      versionResolver: _versionResolver,
      sourceFiles: _cacheRegistry.sourceFiles,
      log: log,
    );
    _registerTracedTool(listPackageSourceFilesTool, listSourceFilesHandler.call);
    log(LoggingLevel.debug, 'registered tool: list_package_source_files');

    final getSourceSliceHandler = GetSourceSliceHandler(
      versionResolver: _versionResolver,
      astAccess: _astAccess,
      log: log,
    );
    _registerTracedTool(getSourceSliceTool, getSourceSliceHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_source_slice');

    final getThrowStatementsHandler = GetThrowStatementsHandler(
      versionResolver: _versionResolver,
      astAccess: _astAccess,
      apiIndex: _cacheRegistry.apiIndex,
      log: log,
    );
    _registerTracedTool(getThrowStatementsTool, getThrowStatementsHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_throw_statements');
  }

  void _registerResources() {
    final metaHandler = MetaResourcesHandler(
      meta: _cacheRegistry.meta,
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
      readme: _cacheRegistry.readme,
      apiIndex: _cacheRegistry.apiIndex,
      sourceFiles: _cacheRegistry.sourceFiles,
    );
    _addTracedResourceTemplate(PackageResourcesHandler.kReadmeTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kReadmeUriTemplate');

    _addTracedResourceTemplate(
      PackageResourcesHandler.kExampleTemplate,
      handler.handleReadResource,
    );
    log(LoggingLevel.debug, 'registered resource template: $kExampleUriTemplate');

    _addTracedResourceTemplate(
      PackageResourcesHandler.kChangelogTemplate,
      handler.handleReadResource,
    );
    log(LoggingLevel.debug, 'registered resource template: $kChangelogUriTemplate');

    _addTracedResourceTemplate(PackageResourcesHandler.kApiTemplate, handler.handleReadResource);
    log(LoggingLevel.debug, 'registered resource template: $kApiUriTemplate');

    _addTracedResourceTemplate(
      PackageResourcesHandler.kPubspecTemplate,
      handler.handleReadResource,
    );
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
