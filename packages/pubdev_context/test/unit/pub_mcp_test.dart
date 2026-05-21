/// Unit tests for [PubMcpServer] initialisation.
library;

import 'dart:async';

import 'package:dart_mcp/client.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/config/config.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

// ─── In-memory channel pair ───────────────────────────────────────────────────

/// Returns a pair of connected [StreamChannel]s for in-process testing.
///
/// Messages sent on the first channel arrive on the second and vice versa.
(StreamChannel<String>, StreamChannel<String>) inProcessChannels() {
  final clientCtrl = StreamController<String>();
  final serverCtrl = StreamController<String>();
  final clientChannel = StreamChannel<String>.withCloseGuarantee(
    serverCtrl.stream,
    clientCtrl.sink,
  );
  final serverChannel = StreamChannel<String>.withCloseGuarantee(
    clientCtrl.stream,
    serverCtrl.sink,
  );
  return (clientChannel, serverChannel);
}

// ─── Test client ─────────────────────────────────────────────────────────────

/// Minimal MCP client used to drive the server during tests.
base class TestMcpClient extends MCPClient {
  TestMcpClient() : super(Implementation(name: 'test-client', version: '0.0.1'));
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

PubMcpServer buildServer(StreamChannel<String> channel, {PubMcpConfig? config}) => PubMcpServer(
  channel,
  config: config ?? const PubMcpConfig(),
  client: PubDevClient(),
  searchCache: ResponseCache<List<PackageSummary>>(),
  packageCache: ResponseCache<PackageDetail>(),
  changelogCache: ResponseCache<List<ChangelogEntry>>(),
  changelogRawCache: ResponseCache<String>(),
  apiIndexCache: ResponseCache<List<DartdocSymbol>>(),
  readmeCache: ResponseCache<String>(),
  symbolDocCache: ResponseCache<String>(),
  metaCache: ResponseCache<String>(),
);

/// Builds a [PubMcpServer] that shuts down cleanly at end of test without a
/// client handshake.
///
/// Drains the server's output stream so [StreamSink.close] can complete, then
/// registers an [addTearDown] that closes the server's input and waits for
/// [PubMcpServer.done]. Safe to call from any test body.
PubMcpServer buildIsolatedServer({PubMcpConfig? config}) {
  final clientCtrl = StreamController<String>();
  final serverCtrl = StreamController<String>();
  // A listener is required so serverCtrl.sink.close() can complete — without
  // one, the 'done' event is never delivered and shutdown hangs.
  serverCtrl.stream.listen(null, onDone: () {});
  final serverChannel = StreamChannel<String>.withCloseGuarantee(
    clientCtrl.stream,
    serverCtrl.sink,
  );
  final server = buildServer(serverChannel, config: config);
  addTearDown(() async {
    await clientCtrl.close(); // ends the peer's listen loop
    await server.done;
  });
  return server;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  // ─── Log level ────────────────────────────────────────────────────────────────
  // Checks a constructor-set property — no MCP handshake or setUp/tearDown
  // shared with the initialized-server group below.

  group('log level', () {
    test('defaults to warning level when no config is supplied', () {
      expect(buildIsolatedServer().loggingLevel, equals(LoggingLevel.warning));
    });

    test('applies debug level from PubMcpConfig', () {
      expect(
        buildIsolatedServer(
          config: const PubMcpConfig(logLevel: LogLevel.debug),
        ).loggingLevel,
        equals(LoggingLevel.debug),
      );
    });

    test('applies info level from PubMcpConfig', () {
      expect(
        buildIsolatedServer(
          config: const PubMcpConfig(logLevel: LogLevel.info),
        ).loggingLevel,
        equals(LoggingLevel.info),
      );
    });

    test('applies error level from PubMcpConfig', () {
      expect(
        buildIsolatedServer(
          config: const PubMcpConfig(logLevel: LogLevel.error),
        ).loggingLevel,
        equals(LoggingLevel.error),
      );
    });
  });

  // ─── Initialized server ───────────────────────────────────────────────────────
  // setUp/tearDown are scoped to this group so they don't affect the log level
  // group above.

  group('PubMcpServer', () {
    late TestMcpClient testClient;
    late PubMcpServer server;
    late ServerConnection serverConnection;

    setUp(() {
      final (clientChannel, serverChannel) = inProcessChannels();
      testClient = TestMcpClient();
      server = buildServer(serverChannel);
      serverConnection = testClient.connectServer(clientChannel);
    });

    tearDown(() async {
      await testClient.shutdown();
      await server.shutdown();
    });

    Future<InitializeResult> doInitialize() async {
      final result = await serverConnection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: testClient.capabilities,
          clientInfo: testClient.implementation,
        ),
      );
      serverConnection.notifyInitialized(InitializedNotification());
      await server.initialized;
      return result;
    }

    // ─── Initialization ─────────────────────────────────────────────────────────

    group('initialize', () {
      test('responds with server name pubdev_context', () async {
        final result = await doInitialize();
        expect(result.serverInfo.name, equals('pubdev_context'));
      });

      test('responds with the current package version', () async {
        final result = await doInitialize();
        expect(result.serverInfo.version, isNotEmpty);
      });

      test('advertises the tools capability', () async {
        final result = await doInitialize();
        expect(result.capabilities.tools, isNotNull);
      });

      test('advertises the logging capability', () async {
        final result = await doInitialize();
        expect(result.capabilities.logging, isNotNull);
      });

      test('advertises the completions capability', () async {
        final result = await doInitialize();
        expect(result.capabilities.completions, isNotNull);
      });

      test('advertises the prompts capability', () async {
        final result = await doInitialize();
        expect(result.capabilities.prompts, isNotNull);
      });

      test('advertises the resources capability', () async {
        final result = await doInitialize();
        expect(result.capabilities.resources, isNotNull);
      });

      test('marks server as ready after initialization completes', () async {
        await doInitialize();
        expect(server.ready, isTrue);
      });
    });

    // ─── Tool registration ───────────────────────────────────────────────────────

    group('tool registration', () {
      test('lists search_packages after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('search_packages'));
      });

      test('search_packages tool has a non-empty description', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'search_packages');
        expect(tool.description, isNotEmpty);
      });

      test('search_packages input schema marks query as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'search_packages');
        expect(tool.inputSchema.required, contains('query'));
      });

      test('lists get_package after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_package'));
      });

      test('get_package input schema marks name as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_package');
        expect(tool.inputSchema.required, contains('name'));
      });

      test('lists get_changelog after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_changelog'));
      });

      test('get_changelog input schema marks name as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_changelog');
        expect(tool.inputSchema.required, contains('name'));
      });

      test('lists get_symbol_documentation after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_symbol_documentation'));
      });

      test('get_symbol_documentation input schema marks package and href as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_symbol_documentation');
        expect(tool.inputSchema.required, containsAll(['package', 'href']));
      });
    });

    // ─── Resource registration ───────────────────────────────────────────────────

    group('resource registration', () {
      test('lists pub://meta/scoring after initialization', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final uris = resources.resources.map((r) => r.uri).toList();
        expect(uris, contains('pub://meta/scoring'));
      });

      test('lists pub://meta/sdk-versions after initialization', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final uris = resources.resources.map((r) => r.uri).toList();
        expect(uris, contains('pub://meta/sdk-versions'));
      });

      test('lists pub://package/{name}/example after initialization', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final uris = templates.resourceTemplates.map((r) => r.uriTemplate).toList();
        expect(uris, contains('pub://package/{name}/example'));
      });

      test('lists pub://package/{name}/changelog after initialization', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final uris = templates.resourceTemplates.map((r) => r.uriTemplate).toList();
        expect(uris, contains('pub://package/{name}/changelog'));
      });

      test('pub://meta/scoring resource has a non-empty name', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final resource = resources.resources.firstWhere((r) => r.uri == 'pub://meta/scoring');
        expect(resource.name, isNotEmpty);
      });

      test('pub://meta/sdk-versions resource has a non-empty name', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final resource = resources.resources.firstWhere(
          (r) => r.uri == 'pub://meta/sdk-versions',
        );
        expect(resource.name, isNotEmpty);
      });

      test('pub://package/{name}/example resource has a non-empty name', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final resource = templates.resourceTemplates.firstWhere(
          (r) => r.uriTemplate == 'pub://package/{name}/example',
        );
        expect(resource.name, isNotEmpty);
      });

      test('pub://package/{name}/changelog resource has a non-empty name', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final resource = templates.resourceTemplates.firstWhere(
          (r) => r.uriTemplate == 'pub://package/{name}/changelog',
        );
        expect(resource.name, isNotEmpty);
      });
    });

    // ─── Prompt registration ─────────────────────────────────────────────────────

    group('prompt registration', () {
      test('lists add-and-setup-package after initialization', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final names = result.prompts.map((p) => p.name).toList();
        expect(names, contains('add-and-setup-package'));
      });

      test('lists analyze-upgrade-impact after initialization', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final names = result.prompts.map((p) => p.name).toList();
        expect(names, contains('analyze-upgrade-impact'));
      });

      test('lists evaluate-alternatives after initialization', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final names = result.prompts.map((p) => p.name).toList();
        expect(names, contains('evaluate-alternatives'));
      });

      test('add-and-setup-package marks package_name as required', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final prompt = result.prompts.firstWhere((p) => p.name == 'add-and-setup-package');
        final arg = prompt.arguments!.firstWhere((a) => a.name == 'package_name');
        expect(arg.required, isTrue);
      });

      test('analyze-upgrade-impact marks all three arguments as required', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final prompt = result.prompts.firstWhere((p) => p.name == 'analyze-upgrade-impact');
        final required = prompt.arguments!.where((a) => a.required == true).map((a) => a.name);
        expect(required, containsAll(['package_name', 'from_version', 'to_version']));
      });

      test('evaluate-alternatives marks use_case as required', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final prompt = result.prompts.firstWhere((p) => p.name == 'evaluate-alternatives');
        final arg = prompt.arguments!.firstWhere((a) => a.name == 'use_case');
        expect(arg.required, isTrue);
      });

      test('evaluate-alternatives marks sdk and platform as optional', () async {
        await doInitialize();
        final result = await serverConnection.listPrompts(ListPromptsRequest());
        final prompt = result.prompts.firstWhere((p) => p.name == 'evaluate-alternatives');
        final sdkArg = prompt.arguments!.firstWhere((a) => a.name == 'sdk');
        final platformArg = prompt.arguments!.firstWhere((a) => a.name == 'platform');
        expect(sdkArg.required, isFalse);
        expect(platformArg.required, isFalse);
      });
    });

    // ─── handleComplete ──────────────────────────────────────────────────────────

    group('handleComplete', () {
      test('returns an empty completion result without throwing', () async {
        await doInitialize();
        final request = CompleteRequest(
          ref: PromptReference(name: 'any'),
          argument: CompletionArgument(name: 'query', value: 'http'),
        );
        final result = await serverConnection.requestCompletions(request);
        expect(result.completion.values, isEmpty);
      });
    });
  });
}
