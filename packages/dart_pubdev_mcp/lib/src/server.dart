/// The dart_pubdev_mcp MCP server.
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
import 'identity.dart';
import 'resources/meta_resources.dart';
import 'resources/package_resources.dart';
import 'tools/browse_api_symbols.dart';
import 'tools/compare_packages.dart';
import 'tools/find_symbols.dart';
import 'tools/get_api_diff.dart';
import 'tools/get_changelog.dart';
import 'tools/get_package.dart';
import 'tools/get_sdk_source_slice.dart';
import 'tools/get_sdk_throw_statements.dart';
import 'tools/get_security_advisories.dart';
import 'tools/get_source_slice.dart';
import 'tools/get_symbol_documentation.dart';
import 'tools/get_throw_statements.dart';
import 'tools/grep_package_source.dart';
import 'tools/list_package_source_files.dart';
import 'tools/list_package_versions.dart';
import 'tools/list_sdk_source_files.dart';
import 'tools/search_packages.dart';
import 'tools/tool_definitions.dart';
import 'tools/tool_response.dart';
import 'tools/version_resolver.dart';
import 'trace/llm_boundary.dart';
import 'trace/wire_trace.dart';
import 'update/update_check_state_store.dart';
import 'update/update_checker.dart';
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
  /// `changelog` (`get_changelog`), `securityAdvisories` (`get_security_advisories`),
  /// `readme` (the package resource handler's
  /// `readme`, `example`, and `changelog` resources), `symbolDoc` (the
  /// symbol-documentation handler), `meta` (the `pub://meta/` resource
  /// handler), and `sdkSourceFiles`/`sdkAst` (shared by `get_sdk_source_slice`,
  /// `list_sdk_source_files`, and `get_sdk_throw_statements`, distinct from
  /// `sourceFiles`/`ast` since they read GitHub tarballs rather than pub.dev
  /// ones). This is the server's sole
  /// cache dependency — every handler-layer store flows through the registry.
  ///
  /// When an enabled [trace] is supplied, every tool call and resource-template
  /// read is wrapped by a central LLM-boundary tracer that assigns a Correlation
  /// Id, records the inbound call and outbound result, and runs the handler
  /// inside a [Zone] carrying the id. When [trace] is null or disabled, no
  /// wrapper is installed and tracing costs nothing.
  ///
  /// When `config.updateCheck` is enabled, an [UpdateChecker] is constructed
  /// — wired to an [UpdateCheckStateStore] rooted at `config.cacheDir`, the
  /// same directory root the tarball cache uses, so its cross-restart
  /// rate-limit state lives alongside it rather than in a second,
  /// uncoordinated location — and fired, fire-and-forget, once [initialize]
  /// completes (see [_runUpdateCheck]). When it is disabled, no
  /// [UpdateChecker] is constructed at all — the Update Check is entirely
  /// inert.
  PubMcpServer(
    super.channel, {
    required PubMcpConfig config,
    required PubDevClient client,
    required CacheRegistry cacheRegistry,
    WireTrace? trace,
  }) : _tracer = trace != null && trace.isEnabled ? LlmBoundaryTracer(trace) : null,
       _client = client,
       _cacheRegistry = cacheRegistry,
       _updateChecker = config.updateCheck
           ? UpdateChecker(
               client: client,
               currentVersion: packageVersion,
               stateStore: UpdateCheckStateStore(directoryPath: config.cacheDir),
             )
           : null,
       super.fromStreamChannel(
         implementation: Implementation(
           name: kMcpServerIdentity,
           title: kMcpServerTitle,
           version: packageVersion,
         ),
         instructions: kServerInstructions,
       ) {
    loggingLevel = _toLoggingLevel(config.logLevel);
    _versionResolver = VersionResolver(client: client, log: log);
    _astAccess = AstAccess(sourceFiles: cacheRegistry.sourceFiles, ast: cacheRegistry.ast);
    _sdkAstAccess = AstAccess(sourceFiles: cacheRegistry.sdkSourceFiles, ast: cacheRegistry.sdkAst);
  }

  /// The central LLM-boundary tracer, or `null` when tracing is disabled.
  final LlmBoundaryTracer? _tracer;
  final PubDevClient _client;
  final CacheRegistry _cacheRegistry;

  /// Runs the Update Check (see `CONTEXT.md`), or `null` when
  /// `config.updateCheck` is disabled.
  final UpdateChecker? _updateChecker;

  /// The pending Update Notice for this session (see `CONTEXT.md`): `null`
  /// until the Update Check resolves and finds a newer Latest Stable Version.
  /// Set once by [_runUpdateCheck]; read and cleared by
  /// [_insertUpdateNoticeIfEligible] on the first eligible tool response.
  Map<String, Object?>? _pendingUpdateNotice;

  /// Completes when this session's Update Check has finished — successfully
  /// or not. `null` when the Update Check is disabled or has not been started
  /// yet ([_runUpdateCheck] has not run). Exists solely so tests can
  /// deterministically await the fire-and-forget background check before
  /// asserting on the next tool-call response; production code never reads it.
  Future<void>? _updateCheckComplete;

  /// Test-only hook for [_updateCheckComplete] — see that field's doc.
  Future<void>? get updateCheckComplete => _updateCheckComplete;

  /// Resolves the Resolved Version for the 9 version-accepting tools that
  /// delegate to it; constructed once alongside [_cacheRegistry].
  late final VersionResolver _versionResolver;

  /// Resolves source files and parsed ASTs for `get_source_slice` and
  /// `get_throw_statements`; constructed once alongside [_cacheRegistry] so
  /// both handlers share the same `sourceFiles`/`ast` cache entries.
  late final AstAccess _astAccess;

  /// Resolves SDK source files and parsed ASTs for `get_sdk_source_slice`,
  /// `list_sdk_source_files`, and `get_sdk_throw_statements`, distinct from
  /// [_astAccess] — wired over `CacheRegistry.sdkSourceFiles`/`sdkAst` rather
  /// than the pub.dev-package caches.
  late final AstAccess _sdkAstAccess;

  @override
  FutureOr<InitializeResult> initialize(InitializeRequest request) async {
    final result = await super.initialize(request);
    _registerTools();
    _registerResources();
    _runUpdateCheck();
    log(LoggingLevel.info, '$kMcpServerIdentity server initialized');
    return result;
  }

  /// Fires the Update Check, fire-and-forget: [initialize] does not await
  /// this, so a slow or failed check never delays the handshake or any tool
  /// call. A no-op when `config.updateCheck` was disabled at construction
  /// time ([_updateChecker] is `null`).
  ///
  /// When the check resolves with a newer Latest Stable Version,
  /// [_pendingUpdateNotice] is set once so the next eligible tool response
  /// carries it (see [_insertUpdateNoticeIfEligible]), and the Update Log
  /// Notification (see `CONTEXT.md`) is pushed to the client via a direct
  /// [sendNotification] call — deliberately bypassing [log]'s own
  /// `loggingLevel` gate, since this is a one-time informational push rather
  /// than a diagnostic line the operator's `--log-level` was ever meant to
  /// filter.
  void _runUpdateCheck() {
    final checker = _updateChecker;
    if (checker == null) return;
    _updateCheckComplete = checker.checkForUpdate().then((latest) {
      if (latest != null) {
        _pendingUpdateNotice = {
          'current': packageVersion,
          'latest': latest,
          'message':
              'A newer version of $kMcpServerIdentity is available '
              '($packageVersion → $latest). Mention this to your user and '
              'suggest running `dart install dart_pubdev_mcp --overwrite` '
              'to upgrade.',
        };
        sendNotification(
          LoggingMessageNotification.methodName,
          LoggingMessageNotification(
            level: LoggingLevel.info,
            data:
                '$kMcpServerIdentity: update available '
                '($packageVersion → $latest) — run '
                '`dart install dart_pubdev_mcp --overwrite` to upgrade.',
          ),
        );
      }
    });
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

  /// Registers [tool], wrapping [impl] with the argument-validation wrapper,
  /// the Update Notice layer, and — when tracing is enabled — the
  /// LLM-boundary tracer.
  ///
  /// Ordering, outermost to innermost: Update Notice layer, tracer, validation,
  /// handler — so a schema-rejected call still appears in the Wire Trace with a
  /// Correlation Id, and the Update Notice layer always sees the exact
  /// [CallToolResult] about to be sent back to the client, whichever of the
  /// inner layers produced it. [registerTool] is called with
  /// `validateArguments: false`: `dart_mcp`'s own schema validation is
  /// disabled for every tool, since it would reject violations as plain text
  /// and bypass the ADR-0002 envelope [_validated] provides instead.
  void _registerTracedTool(
    Tool tool,
    FutureOr<CallToolResult> Function(CallToolRequest) impl,
  ) {
    final validated = _validated(tool, impl);
    final tracer = _tracer;
    final traced = tracer == null ? validated : tracer.wrapTool(validated);
    registerTool(
      tool,
      _withUpdateNotice(traced),
      validateArguments: false,
    );
  }

  /// Wraps [impl] with the always-on Update Notice layer (see `CONTEXT.md`):
  /// on the first eligible successful response after [_pendingUpdateNotice]
  /// is set, inserts it into the response body and clears the pending state so
  /// it is delivered at most once per session.
  FutureOr<CallToolResult> Function(CallToolRequest) _withUpdateNotice(
    FutureOr<CallToolResult> Function(CallToolRequest) impl,
  ) {
    return (request) async {
      final result = await impl(request);
      return _insertUpdateNoticeIfEligible(result);
    };
  }

  /// Inserts [_pendingUpdateNotice] into [result] and clears it, when [result]
  /// is eligible; returns [result] unchanged otherwise.
  ///
  /// Ineligible cases, per `CONTEXT.md`'s Update Notice entry:
  ///   - No notice is pending.
  ///   - [result] is a Tool Error (`isError: true`).
  ///   - [result]'s body is not a single JSON object — covers
  ///     `search_packages`'s bare JSON array, which defers to the next
  ///     eligible call rather than dropping the notice.
  ///
  /// The notice is added to the text block only, never to
  /// `structuredContent` — it is not part of any tool's declared
  /// `outputSchema`, so folding it in would make `structuredContent` stop
  /// conforming to that schema. [result]'s own `structuredContent` (if any)
  /// is carried over unchanged.
  CallToolResult _insertUpdateNoticeIfEligible(CallToolResult result) {
    final notice = _pendingUpdateNotice;
    if (notice == null || (result.isError ?? false)) return result;
    if (result.content.length != 1) return result;
    final content = result.content.single;
    if (content is! TextContent) return result;

    final Object? decoded;
    try {
      decoded = jsonDecode(content.text);
    } on FormatException {
      return result;
    }
    if (decoded is! Map<String, Object?>) return result;

    _pendingUpdateNotice = null;
    return CallToolResult(
      content: [
        TextContent(text: jsonEncode({...decoded, 'dartPubdevMcpUpdate': notice})),
      ],
      structuredContent: result.structuredContent,
      isError: result.isError,
    );
  }

  /// Wraps [impl] so a call's arguments are validated against [tool]'s input
  /// schema before the handler runs.
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
      securityAdvisories: _cacheRegistry.securityAdvisories,
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

    final getSecurityAdvisoriesHandler = GetSecurityAdvisoriesHandler(
      versionResolver: _versionResolver,
      securityAdvisories: _cacheRegistry.securityAdvisories,
      log: log,
    );
    _registerTracedTool(getSecurityAdvisoriesTool, getSecurityAdvisoriesHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_security_advisories');

    final comparePackagesHandler = ComparePackagesHandler(
      versionResolver: _versionResolver,
      packageDetail: _cacheRegistry.packageDetail,
      securityAdvisories: _cacheRegistry.securityAdvisories,
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
      astAccess: _astAccess,
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

    final grepPackageSourceHandler = GrepPackageSourceHandler(
      versionResolver: _versionResolver,
      sourceFiles: _cacheRegistry.sourceFiles,
      log: log,
    );
    _registerTracedTool(grepPackageSourceTool, grepPackageSourceHandler.call);
    log(LoggingLevel.debug, 'registered tool: grep_package_source');

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

    final getSdkSourceSliceHandler = GetSdkSourceSliceHandler(
      astAccess: _sdkAstAccess,
      log: log,
    );
    _registerTracedTool(getSdkSourceSliceTool, getSdkSourceSliceHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_sdk_source_slice');

    final listSdkSourceFilesHandler = ListSdkSourceFilesHandler(
      astAccess: _sdkAstAccess,
      log: log,
    );
    _registerTracedTool(listSdkSourceFilesTool, listSdkSourceFilesHandler.call);
    log(LoggingLevel.debug, 'registered tool: list_sdk_source_files');

    final getSdkThrowStatementsHandler = GetSdkThrowStatementsHandler(
      astAccess: _sdkAstAccess,
      log: log,
    );
    _registerTracedTool(getSdkThrowStatementsTool, getSdkThrowStatementsHandler.call);
    log(LoggingLevel.debug, 'registered tool: get_sdk_throw_statements');
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
