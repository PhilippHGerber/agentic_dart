/// Seam-2 tests: proof that the Wire Trace's central LLM-boundary wrapper is
/// wired into a running [PubMcpServer]. Constructs the server in-process over an
/// in-memory channel with a fake `http.Client` and tracing enabled to a temp
/// directory, drives real `tools/call` and `resources/read` requests, and
/// asserts the inbound and result lines land in the session file under one
/// shared Correlation Id. No spawned binary, no network — runs in the default
/// suite.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/config/config.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/server.dart';
import 'package:pubdev_context/src/trace/wire_trace.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:test/test.dart';

// ─── Mocks ────────────────────────────────────────────────────────────────────

class _MockHttpClient extends Mock implements http.Client {}

base class _TestMcpClient extends MCPClient {
  _TestMcpClient() : super(Implementation(name: 'test-client', version: '0.0.1'));
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

http.Response _json(String body, {int status = 200}) => http.Response(body, status);

http.Response _jsonFile(String name, {int status = 200}) =>
    _json(_readFixture(name), status: status);

void _stubGet(_MockHttpClient mock, String urlSubstring, http.Response response) {
  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains(urlSubstring))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => response);
}

(StreamChannel<String>, StreamChannel<String>) _inProcessChannels() {
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

/// A retry policy that never sleeps, so 404s (and any retryable status) resolve
/// instantly instead of waiting out real backoff delays.
RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

/// The Correlation Id (`#001`, …) embedded in a trace [line].
String? _idOf(String line) => RegExp(r'#\d+').firstMatch(line)?.group(0);

void main() {
  late Directory tempDir;
  late _MockHttpClient mock;
  late _TestMcpClient testClient;
  late PubMcpServer server;
  late ServerConnection serverConnection;
  WireTrace? trace;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pubdev_context_wire_trace_seam2_');
    mock = _MockHttpClient();
    registerFallbackValue(Uri.parse('https://pub.dev'));
    testClient = _TestMcpClient();
  });

  tearDown(() async {
    await testClient.shutdown();
    await server.shutdown();
    trace?.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  /// Builds and connects a server with the fake client and, when [enableTrace],
  /// a Wire Trace writing into [tempDir]. Returns after `initialize` completes.
  Future<void> connect({bool enableTrace = true}) async {
    trace = enableTrace
        ? WireTrace.open(
            directoryPath: tempDir.path,
            serverVersion: '0.0.0-test',
            maxPreviewBytes: 2048,
            concurrency: 5,
            cacheDir: tempDir.path,
          )
        : null;
    final (clientChannel, serverChannel) = _inProcessChannels();
    server = PubMcpServer(
      serverChannel,
      config: const PubMcpConfig(),
      client: PubDevClient(httpClient: mock, retryPolicy: _instant),
      searchCache: ResponseCache<List<PackageSummary>>(),
      packageCache: ResponseCache<PackageDetail>(),
      packageVersionsCache: ResponseCache<List<PackageVersion>>(),
      changelogCache: ResponseCache<List<ChangelogEntry>>(),
      changelogRawCache: ResponseCache<String>(),
      apiIndexCache: ResponseCache<List<DartdocSymbol>>(),
      readmeCache: ResponseCache<String>(),
      symbolDocCache: ResponseCache<String>(),
      sourceFilesCache: ResponseCache<Map<String, String>>(),
      metaCache: ResponseCache<String>(),
      trace: trace,
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
  }

  List<String> traceLines() {
    final files = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('wire-trace-'))
        .toList();
    expect(files, hasLength(1), reason: 'expected exactly one session file');
    return files.single.readAsStringSync().split('\n');
  }

  test('a tool call writes inbound + result lines sharing one Correlation Id', () async {
    _stubGet(mock, '/api/search', _jsonFile('search_result.json'));
    _stubGet(mock, '/api/packages/', _jsonFile('package_info.json'));
    _stubGet(mock, '/score', _jsonFile('package_score.json'));

    await connect();
    await serverConnection.callTool(
      CallToolRequest(name: 'search_packages', arguments: {'query': 'http'}),
    );

    final lines = traceLines();
    final inbound = lines.firstWhere(
      (l) => l.contains('← LLM   tools/call  search_packages'),
    );
    final result = lines.firstWhere(
      (l) => l.contains('→ LLM   result  search_packages'),
    );

    expect(_idOf(inbound), isNotNull);
    expect(_idOf(result), equals(_idOf(inbound)));
    // The full arguments are captured on the inbound continuation line.
    expect(lines.any((l) => l.contains('args: {"query":"http"}')), isTrue);
  });

  test('a resource read is traced like a tool call, under one shared id', () async {
    // `latest` resolution hits /api/packages/htp, which 404s → PACKAGE_NOT_FOUND.
    _stubGet(mock, '/api/packages/htp', _json('', status: 404));

    await connect();
    await serverConnection.readResource(
      ReadResourceRequest(uri: 'pub://package/htp@latest/readme'),
    );

    final lines = traceLines();
    final inbound = lines.firstWhere(
      (l) => l.contains('← LLM   resources/read  pub://package/htp@latest/readme'),
    );
    final result = lines.firstWhere(
      (l) => l.contains('→ LLM   result  pub://package/htp@latest/readme'),
    );

    expect(_idOf(result), equals(_idOf(inbound)));
  });

  test('an error result is rendered with its ERROR code', () async {
    _stubGet(mock, '/api/packages/htp', _json('', status: 404));

    await connect();
    await serverConnection.callTool(
      CallToolRequest(name: 'get_package', arguments: {'name': 'htp'}),
    );

    final lines = traceLines();
    final result = lines.firstWhere(
      (l) => l.contains('→ LLM   result  get_package'),
    );
    final inbound = lines.firstWhere(
      (l) => l.contains('← LLM   tools/call  get_package'),
    );

    expect(result, contains('ERROR PACKAGE_NOT_FOUND'));
    expect(_idOf(result), equals(_idOf(inbound)));
  });

  test('without tracing, no session file is created', () async {
    _stubGet(mock, '/api/search', _jsonFile('search_result.json'));
    _stubGet(mock, '/api/packages/', _jsonFile('package_info.json'));
    _stubGet(mock, '/score', _jsonFile('package_score.json'));

    await connect(enableTrace: false);
    await serverConnection.callTool(
      CallToolRequest(name: 'search_packages', arguments: {'query': 'http'}),
    );

    final files = tempDir
        .listSync()
        .whereType<File>()
        .where((f) => f.uri.pathSegments.last.startsWith('wire-trace-'))
        .toList();
    expect(files, isEmpty);
  });
}
