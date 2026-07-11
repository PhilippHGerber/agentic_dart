/// Unit tests for [PubMcpServer] initialisation.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/config/config.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/resources/package_resources.dart';
import 'package:pubdev_context/src/server.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

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

PubMcpServer buildServer(StreamChannel<String> channel, {PubMcpConfig? config}) {
  final client = PubDevClient();
  return PubMcpServer(
    channel,
    config: config ?? const PubMcpConfig(),
    client: client,
    cacheRegistry: CacheRegistry(client: client),
  );
}

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
      test('responds with server name dart_pubdev', () async {
        final result = await doInitialize();
        expect(result.serverInfo.name, equals('dart_pubdev'));
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

      test('get_symbol_documentation input schema marks package and symbol as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_symbol_documentation');
        expect(tool.inputSchema.required, containsAll(['package', 'symbol']));
      });

      test('lists list_package_versions after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('list_package_versions'));
      });

      test('list_package_versions input schema marks name as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'list_package_versions');
        expect(tool.inputSchema.required, contains('name'));
      });

      test('lists get_source_slice after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_source_slice'));
      });

      test('get_source_slice input schema marks package and file as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_source_slice');
        expect(tool.inputSchema.required, containsAll(['package', 'file']));
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

      test('lists pub://meta/resources after initialization', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final uris = resources.resources.map((r) => r.uri).toList();
        expect(uris, contains('pub://meta/resources'));
      });

      test('lists pub://meta/instructions after initialization', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final uris = resources.resources.map((r) => r.uri).toList();
        expect(uris, contains('pub://meta/instructions'));
      });

      test('lists pub://package/{name}@{version}/example after initialization', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final uris = templates.resourceTemplates.map((r) => r.uriTemplate).toList();
        expect(uris, contains('pub://package/{name}@{version}/example'));
      });

      test('lists pub://package/{name}@{version}/pubspec after initialization', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final uris = templates.resourceTemplates.map((r) => r.uriTemplate).toList();
        expect(uris, contains('pub://package/{name}@{version}/pubspec'));
      });

      test('lists pub://package/{name}@{version}/changelog after initialization', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final uris = templates.resourceTemplates.map((r) => r.uriTemplate).toList();
        expect(uris, contains('pub://package/{name}@{version}/changelog'));
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

      test('pub://meta/resources resource has a non-empty name', () async {
        await doInitialize();
        final resources = await serverConnection.listResources(ListResourcesRequest());
        final resource = resources.resources.firstWhere((r) => r.uri == 'pub://meta/resources');
        expect(resource.name, isNotEmpty);
      });

      test('pub://package/{name}@{version}/example resource has a non-empty name', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final resource = templates.resourceTemplates.firstWhere(
          (r) => r.uriTemplate == 'pub://package/{name}@{version}/example',
        );
        expect(resource.name, isNotEmpty);
      });

      test('pub://package/{name}@{version}/changelog resource has a non-empty name', () async {
        await doInitialize();
        final templates = await serverConnection.listResourceTemplates();
        final resource = templates.resourceTemplates.firstWhere(
          (r) => r.uriTemplate == 'pub://package/{name}@{version}/changelog',
        );
        expect(resource.name, isNotEmpty);
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

      test('offers latest for the {version} argument of a package template', () async {
        await doInitialize();
        final request = CompleteRequest(
          ref: ResourceTemplateReference(uri: kReadmeUriTemplate),
          argument: CompletionArgument(name: 'version', value: ''),
        );
        final result = await serverConnection.requestCompletions(request);
        expect(result.completion.values, contains('latest'));
      });

      test('filters the {version} completion by the typed prefix', () async {
        await doInitialize();
        final request = CompleteRequest(
          ref: ResourceTemplateReference(uri: kApiUriTemplate),
          argument: CompletionArgument(name: 'version', value: 'la'),
        );
        final result = await serverConnection.requestCompletions(request);
        expect(result.completion.values, equals(['latest']));
      });

      test('returns no {version} values when the prefix matches nothing', () async {
        await doInitialize();
        final request = CompleteRequest(
          ref: ResourceTemplateReference(uri: kChangelogUriTemplate),
          argument: CompletionArgument(name: 'version', value: 'zzz'),
        );
        final result = await serverConnection.requestCompletions(request);
        expect(result.completion.values, isEmpty);
      });

      test('returns empty completion for an unknown argument name', () async {
        await doInitialize();
        final request = CompleteRequest(
          ref: ResourceTemplateReference(uri: kReadmeUriTemplate),
          argument: CompletionArgument(name: 'nonsense', value: ''),
        );
        final result = await serverConnection.requestCompletions(request);
        expect(result.completion.values, isEmpty);
      });

      test('returns empty {name} completion when the search cache is cold', () async {
        await doInitialize();
        final request = CompleteRequest(
          ref: ResourceTemplateReference(uri: kReadmeUriTemplate),
          argument: CompletionArgument(name: 'name', value: 'ht'),
        );
        final result = await serverConnection.requestCompletions(request);
        expect(result.completion.values, isEmpty);
      });
    });
  });

  // ─── handleComplete against warm facades ────────────────────────────────────
  //
  // The cold-cache handleComplete tests above run against `buildServer`'s real
  // (unmocked) PubDevClient. These warm the `searchResults` and `versionList`
  // facades via real tool calls against a fake `http.Client`, then assert the
  // completion reads the warm entry and issues no further pub.dev call.

  group('handleComplete against warm facades', () {
    late _MockHttpClient mockHttp;
    late TestMcpClient testClient;
    late PubMcpServer server;
    late ServerConnection serverConnection;

    setUp(() async {
      mockHttp = _MockHttpClient();
      registerFallbackValue(Uri.parse('https://pub.dev'));
      final client = PubDevClient(httpClient: mockHttp, retryPolicy: _instant);
      final (clientChannel, serverChannel) = inProcessChannels();
      testClient = TestMcpClient();
      server = PubMcpServer(
        serverChannel,
        config: const PubMcpConfig(),
        client: client,
        cacheRegistry: CacheRegistry(client: client),
      );
      serverConnection = testClient.connectServer(clientChannel);
      await serverConnection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: testClient.capabilities,
          clientInfo: testClient.implementation,
        ),
      );
      serverConnection.notifyInitialized(InitializedNotification());
      await server.initialized;
    });

    tearDown(() async {
      await testClient.shutdown();
      await server.shutdown();
    });

    test('{name} completion returns names from a warm search cache, no pub.dev call', () async {
      _stubUrl(mockHttp, '/api/search', _jsonFixture('search_result.json'));
      _stubUrl(mockHttp, '/api/packages/', _jsonFixture('package_info.json'));
      _stubUrl(mockHttp, '/score', _jsonFixture('package_score.json'));

      await serverConnection.callTool(
        CallToolRequest(name: 'search_packages', arguments: {'query': 'http'}),
      );
      clearInteractions(mockHttp);

      final result = await serverConnection.requestCompletions(
        CompleteRequest(
          ref: ResourceTemplateReference(uri: kReadmeUriTemplate),
          argument: CompletionArgument(name: 'name', value: 'ht'),
        ),
      );

      expect(result.completion.values, contains('http'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test(
      '{version} completion returns versions from a warm version list, no pub.dev call',
      () async {
        _stubUrl(mockHttp, '/api/packages/http', _jsonFixture('package_versions.json'));

        await serverConnection.callTool(
          CallToolRequest(name: 'list_package_versions', arguments: {'name': 'http'}),
        );
        clearInteractions(mockHttp);

        final result = await serverConnection.requestCompletions(
          CompleteRequest(
            ref: ResourceTemplateReference(uri: kReadmeUriTemplate),
            argument: CompletionArgument(name: 'version', value: '1.2'),
            context: CompletionContext(arguments: {'name': 'http'}),
          ),
        );

        expect(result.completion.values, contains('1.2.0'));
        verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
      },
    );
  });
}

// ─── Fixture helpers for the warm-facade completion tests ──────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _jsonFixture(String name) => http.Response(_readFixture(name), 200);

RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

void _stubUrl(_MockHttpClient mock, String urlFragment, http.Response response) {
  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains(urlFragment))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => response);
}
