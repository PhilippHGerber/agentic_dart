/// Unit tests for [PubMcpServer] initialisation.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/config/config.dart';
import 'package:dart_pubdev_mcp/src/data/pub_client.dart';
import 'package:dart_pubdev_mcp/src/identity.dart';
import 'package:dart_pubdev_mcp/src/resources/package_resources.dart';
import 'package:dart_pubdev_mcp/src/server.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart' show listPackageVersionsTool;
import 'package:dart_pubdev_mcp/src/tools/tool_descriptions.dart' show kServerInstructions;
import 'package:dart_pubdev_mcp/src/update/update_check_state_store.dart';
import 'package:dart_pubdev_mcp/src/version.dart';
import 'package:mocktail/mocktail.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

import '../support/harness.dart';
import '../support/pub_stubs.dart';
import '../support/schema_conformance.dart';

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

/// Builds a [PubMcpServer] wired to a real (unmocked) [PubDevClient].
///
/// Defaults to `updateCheck: false` when [config] is omitted: this helper's
/// [PubDevClient] is a live one, so leaving the Update Check enabled would
/// fire a real network call to pub.dev on every `initialize()` in this file's
/// many server-behavior tests, none of which exercise the Update Check itself
/// (see the dedicated `update notice` group below, which builds its own
/// server against a mocked `TestStack`).
PubMcpServer buildServer(StreamChannel<String> channel, {PubMcpConfig? config}) {
  final client = PubDevClient();
  return PubMcpServer(
    channel,
    config: config ?? const PubMcpConfig(updateCheck: false),
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
      test('responds with server name dart-pubdev-explorer', () async {
        final result = await doInitialize();
        expect(result.serverInfo.name, equals('dart-pubdev-explorer'));
      });

      test('responds with a human-readable server title', () async {
        final result = await doInitialize();
        expect(result.serverInfo.title, equals(kMcpServerTitle));
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

      test('get_package input schema marks package as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_package');
        expect(tool.inputSchema.required, contains('package'));
      });

      test('lists get_changelog after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_changelog'));
      });

      test('get_changelog input schema marks package as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_changelog');
        expect(tool.inputSchema.required, contains('package'));
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

      test('list_package_versions input schema marks package as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'list_package_versions');
        expect(tool.inputSchema.required, contains('package'));
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

      test('lists get_sdk_source_slice after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_sdk_source_slice'));
      });

      test('get_sdk_source_slice input schema marks sdk and file as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_sdk_source_slice');
        expect(tool.inputSchema.required, containsAll(['sdk', 'file']));
      });

      test(
        'get_sdk_source_slice input schema declares library and package as optional '
        '(the per-sdk selector is validated by the handler, not the schema)',
        () async {
          await doInitialize();
          final tools = await serverConnection.listTools(ListToolsRequest());
          final tool = tools.tools.firstWhere((t) => t.name == 'get_sdk_source_slice');
          expect(tool.inputSchema.required, isNot(contains('library')));
          expect(tool.inputSchema.required, isNot(contains('package')));
        },
      );

      test('lists list_sdk_source_files after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('list_sdk_source_files'));
      });

      test('list_sdk_source_files input schema marks only sdk as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'list_sdk_source_files');
        expect(tool.inputSchema.required, equals(['sdk']));
      });

      test('lists get_sdk_release_notes after initialization', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toList();
        expect(names, contains('get_sdk_release_notes'));
      });

      test('get_sdk_release_notes input schema marks only sdk as required', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final tool = tools.tools.firstWhere((t) => t.name == 'get_sdk_release_notes');
        expect(tool.inputSchema.required, equals(['sdk']));
      });

      // All 19 tools this server registers — kept in sync with
      // tool_definitions.dart. Used to assert every tool carries a title and
      // truthful, read-only/open-world annotations.
      const allToolNames = [
        'search_packages',
        'get_package',
        'get_changelog',
        'get_security_advisories',
        'browse_api_symbols',
        'find_symbols',
        'get_symbol_documentation',
        'get_source_slice',
        'list_package_source_files',
        'grep_package_source',
        'get_throw_statements',
        'compare_packages',
        'list_package_versions',
        'get_api_diff',
        'get_sdk_source_slice',
        'list_sdk_source_files',
        'get_sdk_throw_statements',
        'grep_sdk_source',
        'get_sdk_release_notes',
      ];

      test('lists exactly the 19 expected tools', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final names = tools.tools.map((t) => t.name).toSet();
        expect(names, equals(allToolNames.toSet()));
      });

      test('every registered tool is named in kServerInstructions', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        for (final name in tools.tools.map((t) => t.name)) {
          expect(
            kServerInstructions,
            contains(name),
            reason: '$name should be named in kServerInstructions',
          );
        }
      });

      test('every registered tool has a row in README.md', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        final readme = File(
          '${Directory.current.path}/README.md',
        ).readAsStringSync();
        for (final name in tools.tools.map((t) => t.name)) {
          expect(readme, contains(name), reason: '$name should have a row in README.md');
        }
      });

      test('every tool has a non-empty, no-trailing-period title', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        for (final name in allToolNames) {
          final tool = tools.tools.firstWhere((t) => t.name == name);
          final title = tool.title;
          expect(title, isNotNull, reason: '$name should have a title');
          if (title == null) continue;
          expect(title, isNotEmpty, reason: '$name title should be non-empty');
          expect(
            title.endsWith('.'),
            isFalse,
            reason: '$name title should not have a trailing period',
          );
        }
      });

      test('every tool declares readOnlyHint and openWorldHint as true', () async {
        await doInitialize();
        final tools = await serverConnection.listTools(ListToolsRequest());
        for (final name in allToolNames) {
          final tool = tools.tools.firstWhere((t) => t.name == name);
          final annotations = tool.toolAnnotations;
          expect(annotations, isNotNull, reason: '$name should have annotations');
          if (annotations == null) continue;
          expect(
            annotations.readOnlyHint,
            isTrue,
            reason: '$name should declare readOnlyHint: true',
          );
          expect(
            annotations.openWorldHint,
            isTrue,
            reason: '$name should declare openWorldHint: true',
          );
        }
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
    late TestStack stack;
    late MockHttpClient mockHttp;
    late TestMcpClient testClient;
    late PubMcpServer server;
    late ServerConnection serverConnection;

    setUp(() async {
      stack = TestStack();
      mockHttp = stack.http;
      final (clientChannel, serverChannel) = inProcessChannels();
      testClient = TestMcpClient();
      server = PubMcpServer(
        serverChannel,
        // The Update Check would otherwise race the `clearInteractions` calls
        // below and contaminate their `verifyNever(mockHttp.get(...))`
        // assertions — this group doesn't exercise the Update Check itself
        // (see the dedicated `update notice` group).
        config: const PubMcpConfig(updateCheck: false),
        client: stack.client,
        cacheRegistry: stack.caches,
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
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: ok(readFixture('search_result.json')),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/',
        response: ok(readFixture('package_info.json')),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/score',
        response: ok(readFixture('package_score.json')),
      );

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
        stubUrl(
          mock: mockHttp,
          urlFragment: '/api/packages/http',
          response: ok(readFixture('package_versions.json')),
        );

        await serverConnection.callTool(
          CallToolRequest(name: 'list_package_versions', arguments: {'package': 'http'}),
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

  // ─── Argument validation ────────────────────────────────────────
  //
  // The central `_validated` wrapper in `server.dart` runs `tool.inputSchema
  // .validate()` ahead of every handler. A schema violation short-circuits to
  // an ADR-0002 `INVALID_ARGUMENT` envelope without the handler — or a
  // pub.dev call — ever running; a valid call passes through untouched.

  group('argument validation', () {
    late TestStack stack;
    late MockHttpClient mockHttp;
    late TestMcpClient testClient;
    late PubMcpServer server;
    late ServerConnection serverConnection;

    setUp(() async {
      stack = TestStack();
      mockHttp = stack.http;
      final (clientChannel, serverChannel) = inProcessChannels();
      testClient = TestMcpClient();
      server = PubMcpServer(
        serverChannel,
        // See the matching comment in the `handleComplete against warm
        // facades` group above — this group's `verifyNever(mockHttp.get(...))`
        // assertions would otherwise race the Update Check's background call.
        config: const PubMcpConfig(updateCheck: false),
        client: stack.client,
        cacheRegistry: stack.caches,
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

    /// Decodes a tool result's single text block as JSON.
    Map<String, Object?> decodeBody(CallToolResult result) =>
        jsonDecode((result.content.single as TextContent).text) as Map<String, Object?>;

    /// Decodes an ADR-0002 error envelope's nested `error` object.
    Map<String, Object?> decodeError(CallToolResult result) {
      final error = decodeBody(result)['error'];
      if (error is! Map<String, Object?>) {
        fail('expected an ADR-0002 error envelope, got: ${decodeBody(result)}');
      }
      return error;
    }

    test(
      'a limit above the schema maximum returns an ADR-0002 INVALID_ARGUMENT envelope',
      () async {
        final result = await serverConnection.callTool(
          CallToolRequest(
            name: 'browse_api_symbols',
            arguments: {'package': 'http', 'query': 'Client', 'limit': 99},
          ),
        );

        expect(result.isError, isTrue);
        expect(decodeError(result)['code'], equals('INVALID_ARGUMENT'));
        // browse_api_symbols' own inline `limit > 25` check was deleted in
        // favor of the schema's `maximum: 25` — proves the central wrapper,
        // not stray handler code, is what rejects this call.
        verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
      },
    );

    test('a missing required argument returns an ADR-0002 INVALID_ARGUMENT envelope', () async {
      final result = await serverConnection.callTool(
        CallToolRequest(name: 'find_symbols', arguments: {'query': 'Client'}),
      );

      expect(result.isError, isTrue);
      expect(decodeError(result)['code'], equals('INVALID_ARGUMENT'));
      verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
    });

    test('the rejection body is JSON, never a plain-text validation message', () async {
      final result = await serverConnection.callTool(
        CallToolRequest(name: 'find_symbols', arguments: {'query': 'Client'}),
      );

      // dart_mcp's own (disabled) validation would emit plain Content.text
      // lines that are not JSON at all; decoding must succeed.
      expect(() => decodeBody(result), returnsNormally);
    });

    test(
      'a schema-violating packages list on compare_packages is rejected before any fetch',
      () async {
        final result = await serverConnection.callTool(
          CallToolRequest(
            name: 'compare_packages',
            arguments: {
              'packages': ['http'],
            },
          ),
        );

        expect(result.isError, isTrue);
        expect(decodeError(result)['code'], equals('INVALID_ARGUMENT'));
        verifyNever(() => mockHttp.get(any(), headers: any(named: 'headers')));
      },
    );

    test('a valid call reaches the handler unchanged', () async {
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/http',
        response: ok(readFixture('package_versions.json')),
      );

      final result = await serverConnection.callTool(
        CallToolRequest(name: 'list_package_versions', arguments: {'package': 'http'}),
      );

      expect(result.isError, isNull);
      final decoded = decodeBody(result);
      expect(decoded['package'], equals('http'));
      expect(decoded, contains('stable'));
    });
  });

  // ─── Update Notice ──────────────────────────────────────────────────────────
  //
  // See `CONTEXT.md`'s Update Check / Update Notice glossary entries. Every
  // case drives real tool calls through the harness and asserts on the JSON
  // response body — never on the checker's internals. `server
  // .updateCheckComplete` is a test-only synchronization hook (see its doc in
  // `server.dart`) that lets these tests deterministically await the
  // fire-and-forget background check before asserting on the next tool-call
  // response, without the production code path ever waiting on it.

  group('update notice', () {
    late Directory tempDir;
    late TestStack stack;
    late MockHttpClient mockHttp;
    late TestMcpClient testClient;
    late PubMcpServer server;
    late ServerConnection serverConnection;

    /// Collects every `LoggingMessageNotification` the server sends, from the
    /// moment [startServer] connects onward. [ServerConnection.onLog] is a
    /// broadcast stream that does not buffer past events, so this must be
    /// subscribed before [_runUpdateCheck] can possibly fire — i.e. before
    /// `initialize` — for the Update Log Notification tests below to be able
    /// to observe it.
    late List<LoggingMessageNotification> logNotifications;
    late StreamSubscription<LoggingMessageNotification> logSubscription;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_update_notice_test_');
      stack = TestStack();
      mockHttp = stack.http;
      logNotifications = [];
    });

    tearDown(() async {
      await logSubscription.cancel();
      await testClient.shutdown();
      await server.shutdown();
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    /// Builds and initializes a [PubMcpServer] against [against] (defaults to
    /// [stack]), rooted at [cacheDir] (defaults to this test's [tempDir] — the
    /// Update Check's persisted rate-limit state lives here), then awaits the
    /// session's Update Check before returning — so every test's first
    /// `callTool` sees a resolved (or, for the opt-out case, never-started)
    /// pending-notice state rather than racing the background check.
    ///
    /// Also awaits a short additional delay after the Update Check resolves:
    /// [PubMcpServer._runUpdateCheck] sends the Update Log Notification via a
    /// direct `sendNotification` call in the same synchronous callback that
    /// resolves [PubMcpServer.updateCheckComplete], but delivery to
    /// [logNotifications] happens asynchronously over the in-process channel
    /// — this delay lets it land before a test asserts on it without ever
    /// making a tool call.
    Future<void> startServer({
      bool updateCheck = true,
      TestStack? against,
      String? cacheDir,
      LogLevel logLevel = LogLevel.warning,
    }) async {
      final (clientChannel, serverChannel) = inProcessChannels();
      testClient = TestMcpClient();
      server = PubMcpServer(
        serverChannel,
        config: PubMcpConfig(
          updateCheck: updateCheck,
          cacheDir: cacheDir ?? tempDir.path,
          logLevel: logLevel,
        ),
        client: (against ?? stack).client,
        cacheRegistry: (against ?? stack).caches,
      );
      serverConnection = testClient.connectServer(clientChannel);
      logSubscription = serverConnection.onLog.listen(logNotifications.add);
      await serverConnection.initialize(
        InitializeRequest(
          protocolVersion: ProtocolVersion.latestSupported,
          capabilities: testClient.capabilities,
          clientInfo: testClient.implementation,
        ),
      );
      serverConnection.notifyInitialized(InitializedNotification());
      await server.initialized;
      await server.updateCheckComplete;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    /// Asserts [mock] was never called for `dart_pubdev_mcp`'s own
    /// self-check endpoint.
    void verifyNoSelfCheckCall(MockHttpClient mock) {
      verifyNever(
        () => mock.get(
          any(that: predicate<Uri>((u) => u.toString().contains('/api/packages/dart_pubdev_mcp'))),
          headers: any(named: 'headers'),
        ),
      );
    }

    Map<String, Object?> decodeBody(CallToolResult result) =>
        jsonDecode((result.content.single as TextContent).text) as Map<String, Object?>;

    Future<CallToolResult> listHttpVersions() => serverConnection.callTool(
      CallToolRequest(name: 'list_package_versions', arguments: {'package': 'http'}),
    );

    /// Asserts [result]'s `dartPubdevMcpUpdate` object carries [latest] and a
    /// `message` instructing the model to relay the update — not pinned to
    /// exact wording, since that's prose, not a contract.
    void expectUpdateNotice(CallToolResult result, {required String latest}) {
      final notice = decodeBody(result)['dartPubdevMcpUpdate'];
      if (notice is! Map<String, Object?>) {
        fail('expected dartPubdevMcpUpdate to be a JSON object, got: $notice');
      }
      expect(notice['current'], packageVersion);
      expect(notice['latest'], latest);
      expect(notice['message'], allOf(isA<String>(), contains(packageVersion), contains(latest)));
    }

    test('appears on the first eligible response when a newer version exists', () async {
      stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
      stubPackageInfo(mockHttp);
      await startServer();

      final result = await listHttpVersions();

      expect(result.isError, isNull);
      expectUpdateNotice(result, latest: '999.0.0');
    });

    test('is absent when the server is already at the latest stable version', () async {
      stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: packageVersion);
      stubPackageInfo(mockHttp);
      await startServer();

      final result = await listHttpVersions();

      expect(decodeBody(result), isNot(contains('dartPubdevMcpUpdate')));
    });

    test(
      'never appears in structuredContent, which keeps conforming to outputSchema',
      () async {
        stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
        stubPackageInfo(mockHttp);
        await startServer();

        final result = await listHttpVersions();

        expect(decodeBody(result), contains('dartPubdevMcpUpdate'));
        expect(result.structuredContent, isNot(contains('dartPubdevMcpUpdate')));
        expectConformsToOutputSchema(listPackageVersionsTool, result.structuredContent);
      },
    );

    test('appears at most once per session', () async {
      stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
      stubPackageInfo(mockHttp);
      await startServer();

      final first = await listHttpVersions();
      expect(decodeBody(first), contains('dartPubdevMcpUpdate'));

      final second = await listHttpVersions();
      expect(decodeBody(second), isNot(contains('dartPubdevMcpUpdate')));
    });

    test('a search_packages first call defers the notice to the next eligible call', () async {
      stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/search',
        response: ok(readFixture('search_result.json')),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/api/packages/',
        response: ok(readFixture('package_info.json')),
      );
      stubUrl(
        mock: mockHttp,
        urlFragment: '/score',
        response: ok(readFixture('package_score.json')),
      );
      await startServer();

      final searchResult = await serverConnection.callTool(
        CallToolRequest(name: 'search_packages', arguments: {'query': 'http'}),
      );
      // search_packages' response body is a bare JSON array — not eligible.
      final decodedArray = jsonDecode((searchResult.content.single as TextContent).text);
      expect(decodedArray, isA<List<Object?>>());

      stubPackageInfo(mockHttp);
      final next = await listHttpVersions();

      expect(decodeBody(next), contains('dartPubdevMcpUpdate'));
    });

    test('a Tool Error response never carries the notice', () async {
      stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
      stubPackageInfo(mockHttp, packageName: 'missing-package', statusCode: 404);
      await startServer();

      final errorResult = await serverConnection.callTool(
        CallToolRequest(name: 'list_package_versions', arguments: {'package': 'missing-package'}),
      );
      expect(errorResult.isError, isTrue);
      expect(decodeBody(errorResult), isNot(contains('dartPubdevMcpUpdate')));

      // The notice is still pending — the next successful call carries it.
      stubPackageInfo(mockHttp);
      final next = await listHttpVersions();
      expect(decodeBody(next), contains('dartPubdevMcpUpdate'));
    });

    test('the opt-out flag suppresses the check end-to-end', () async {
      stubPackageInfo(mockHttp);
      await startServer(updateCheck: false);

      expect(server.updateCheckComplete, isNull);

      final first = await listHttpVersions();
      final second = await listHttpVersions();

      expect(decodeBody(first), isNot(contains('dartPubdevMcpUpdate')));
      expect(decodeBody(second), isNot(contains('dartPubdevMcpUpdate')));
      verifyNoSelfCheckCall(mockHttp);
    });

    test('a network failure during the check never surfaces and never delays a call', () async {
      stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', statusCode: 500);
      stubPackageInfo(mockHttp);
      await startServer();

      final result = await listHttpVersions();

      expect(result.isError, isNull);
      expect(decodeBody(result), isNot(contains('dartPubdevMcpUpdate')));
    });

    // ─── Update Log Notification (ticket 02) ────────────────────────────────
    //
    // Same trigger and eligibility as the in-band notice above, delivered
    // instead as a `notifications/message` push — asserted here purely via
    // `logNotifications`, populated from `serverConnection.onLog` (see
    // `startServer`'s doc comment). No tool call is made in these tests: the
    // point is that this channel reaches the client independent of any
    // tool-call response.

    group('Update Log Notification', () {
      test('arrives when a newer version exists, independent of any tool call', () async {
        stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
        await startServer();

        expect(logNotifications, hasLength(1));
        expect(
          logNotifications.single.data,
          equals(
            'dart-pubdev-explorer: update available ($packageVersion → 999.0.0) — run '
            '`dart install dart_pubdev_mcp --overwrite` to upgrade.',
          ),
        );
      });

      test('is absent when the server is already at the latest stable version', () async {
        stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: packageVersion);
        await startServer();

        expect(logNotifications, isEmpty);
      });

      test('is absent when the Update Check is disabled', () async {
        stubPackageInfo(mockHttp);
        await startServer(updateCheck: false);

        expect(logNotifications, isEmpty);
        verifyNoSelfCheckCall(mockHttp);
      });

      test('still arrives when the configured log level is above info', () async {
        stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
        await startServer(logLevel: LogLevel.error);

        expect(logNotifications, hasLength(1));
        expect(
          logNotifications.single.data,
          equals(
            'dart-pubdev-explorer: update available ($packageVersion → 999.0.0) — run '
            '`dart install dart_pubdev_mcp --overwrite` to upgrade.',
          ),
        );
      });
    });

    // ─── Cross-restart persistence (ticket 03) ──────────────────────────────
    //
    // The rate-limit state lives in a small file inside `cacheDir` (see
    // `UpdateCheckStateStore`). These cases drive the same MCP harness as the
    // rest of this group — no new test seam — extended with a second server
    // constructed against the same `tempDir`.

    group('cross-restart persistence', () {
      test(
        'a second server sharing the cache directory reuses the persisted '
        'result without a second HTTP call',
        () async {
          stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
          stubPackageInfo(mockHttp);
          await startServer();

          // Tear down the first server before constructing the second against
          // the same cache directory.
          await testClient.shutdown();
          await server.shutdown();

          final secondStack = TestStack();
          addTearDown(secondStack.close);
          stubPackageInfo(secondStack.http);
          await startServer(against: secondStack);

          final result = await listHttpVersions();

          expect(result.isError, isNull);
          expectUpdateNotice(result, latest: '999.0.0');
          verifyNoSelfCheckCall(secondStack.http);
        },
      );

      test(
        'a server whose persisted state is older than the rate-limit window performs a fresh check',
        () async {
          await UpdateCheckStateStore(directoryPath: tempDir.path).write(
            UpdateCheckState(
              checkedAt: DateTime.now().subtract(const Duration(hours: 25)),
              latestVersion: '1.0.0',
            ),
          );
          stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
          stubPackageInfo(mockHttp);
          await startServer();

          final result = await listHttpVersions();

          expectUpdateNotice(result, latest: '999.0.0');
          verify(
            () => mockHttp.get(
              any(
                that: predicate<Uri>((u) => u.toString().contains('/api/packages/dart_pubdev_mcp')),
              ),
              headers: any(named: 'headers'),
            ),
          ).called(1);
        },
      );

      test('a corrupted persisted state file is treated as no persisted state', () async {
        File(
          '${tempDir.path}${Platform.pathSeparator}update-check.json',
        ).writeAsStringSync('not json at all {{{');
        stubPackageInfo(mockHttp, packageName: 'dart_pubdev_mcp', version: '999.0.0');
        stubPackageInfo(mockHttp);
        await startServer();

        final result = await listHttpVersions();

        expectUpdateNotice(result, latest: '999.0.0');
      });
    });
  });
}
