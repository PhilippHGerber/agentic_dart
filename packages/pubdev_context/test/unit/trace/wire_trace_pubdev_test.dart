/// Seam-2 tests for the pub.dev boundary: proof that a traced tool call's
/// pub.dev traffic and its cache hits are captured in the Wire Trace, correlated
/// to the inbound LLM request via one shared Correlation Id.
///
/// Constructs a [PubMcpServer] in-process over an in-memory channel with a fake
/// `http.Client` in [PubDevClient] and tracing enabled to a temp directory, then
/// drives real `tools/call` requests. This is the only place that proves the
/// central wrapper fired, the [Zone] propagated the id into [PubDevClient] and
/// the shared caches, and both emitted. No spawned binary, no network — runs in
/// the default suite.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_mcp/client.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/config/config.dart';
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

http.Response _json(String body, {int status = 200}) => http.Response(
  body,
  status,
  headers: const {'content-type': 'application/vnd.pub.v2+json'},
);

http.Response _jsonFile(String name) => _json(_readFixture(name));

void _stubGet(
  _MockHttpClient mock,
  String urlSubstring,
  http.Response response, {
  Duration delay = Duration.zero,
}) {
  when(
    () => mock.get(
      any(that: predicate<Uri>((u) => u.toString().contains(urlSubstring))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return response;
  });
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

/// A retry policy that never sleeps, so any retryable status resolves instantly.
RetryPolicy get _instant => RetryPolicy(delay: (_) async {});

/// The Correlation Id (`#001`, …) embedded in a trace [line], or `null`.
String? _idOf(String line) => RegExp(r'#\d+').firstMatch(line)?.group(0);

void main() {
  late Directory tempDir;
  late _MockHttpClient mock;
  late _TestMcpClient testClient;
  late PubMcpServer server;
  late ServerConnection serverConnection;
  WireTrace? trace;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pubdev_context_wire_trace_pub_');
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

  /// Builds and connects a server with the fake client and a Wire Trace writing
  /// into [tempDir], with the trace injected into both the client and every
  /// cache. Returns after `initialize` completes.
  Future<void> connect() async {
    trace = WireTrace.open(
      directoryPath: tempDir.path,
      serverVersion: '0.0.0-test',
      maxPreviewBytes: 2048,
      concurrency: 5,
      cacheDir: tempDir.path,
    );
    final activeTrace = trace;
    final (clientChannel, serverChannel) = _inProcessChannels();
    final client = PubDevClient(httpClient: mock, retryPolicy: _instant, trace: activeTrace);
    server = PubMcpServer(
      serverChannel,
      config: const PubMcpConfig(),
      client: client,
      cacheRegistry: CacheRegistry(client: client, trace: activeTrace),
      trace: activeTrace,
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

  test('a tool call hitting pub.dev shows correlated inbound, pub, and result lines', () async {
    _stubGet(mock, '/api/packages/http', _jsonFile('package_info.json'));

    await connect();
    await serverConnection.callTool(
      CallToolRequest(name: 'list_package_versions', arguments: {'name': 'http'}),
    );

    final lines = traceLines();
    final inbound = lines.firstWhere(
      (l) => l.contains('← LLM   tools/call  list_package_versions'),
    );
    final request = lines.firstWhere(
      (l) => l.contains('→ pub  GET /api/packages/http'),
    );
    final response = lines.firstWhere(
      (l) => l.contains('← pub  200 /api/packages/http'),
    );
    final result = lines.firstWhere(
      (l) => l.contains('→ LLM   result  list_package_versions'),
    );

    final id = _idOf(inbound);
    expect(id, isNotNull);
    expect(_idOf(request), equals(id));
    expect(_idOf(response), equals(id));
    expect(_idOf(result), equals(id));
    // The response trailer carries latency, size, and a compact content type.
    expect(response, contains(' ms'));
    expect(response, contains('JSON'));
  });

  test(
    'a cached tool call shows a cache-hit line and no pub.dev lines, under its own id',
    () async {
      _stubGet(mock, '/api/packages/http', _jsonFile('package_info.json'));

      await connect();
      // First call warms the cache (and produces pub lines under its own id).
      await serverConnection.callTool(
        CallToolRequest(name: 'list_package_versions', arguments: {'name': 'http'}),
      );
      // Second call must be served from cache: a ⚡ cache hit and no new pub call.
      await serverConnection.callTool(
        CallToolRequest(name: 'list_package_versions', arguments: {'name': 'http'}),
      );

      final lines = traceLines();
      final cacheHit = lines.firstWhere(
        (l) => l.contains('⚡ cache hit  versions:http'),
      );
      final hitId = _idOf(cacheHit);
      expect(hitId, isNotNull);

      // Exactly one pub request went out across both calls — the second was cached.
      expect(
        lines.where((l) => l.contains('→ pub  GET /api/packages/http')),
        hasLength(1),
      );

      // The cache hit belongs to the second inbound call, and no pub line shares
      // that id.
      final inboundIds = lines
          .where((l) => l.contains('← LLM   tools/call  list_package_versions'))
          .map(_idOf)
          .toList();
      expect(inboundIds, hasLength(2));
      expect(inboundIds.last, equals(hitId));
      expect(
        lines.where((l) => (l.contains('→ pub') || l.contains('← pub')) && _idOf(l) == hitId),
        isEmpty,
      );
    },
  );

  test(
    'two concurrent tool calls stay fully attributable by id — no cross-contamination',
    () async {
      // Delay the responses so the two calls are genuinely in flight together and
      // their boundary lines interleave in the file.
      _stubGet(
        mock,
        '/api/packages/http',
        _jsonFile('package_info.json'),
        delay: const Duration(milliseconds: 30),
      );
      _stubGet(
        mock,
        '/api/packages/dio',
        _jsonFile('package_info.json'),
        delay: const Duration(milliseconds: 30),
      );

      await connect();
      await Future.wait([
        serverConnection.callTool(
          CallToolRequest(name: 'list_package_versions', arguments: {'name': 'http'}),
        ),
        serverConnection.callTool(
          CallToolRequest(name: 'list_package_versions', arguments: {'name': 'dio'}),
        ),
      ]);

      final lines = traceLines();
      final reqHttp = lines.firstWhere((l) => l.contains('→ pub  GET /api/packages/http'));
      final reqDio = lines.firstWhere((l) => l.contains('→ pub  GET /api/packages/dio'));
      final resHttp = lines.firstWhere((l) => l.contains('← pub  200 /api/packages/http'));
      final resDio = lines.firstWhere((l) => l.contains('← pub  200 /api/packages/dio'));

      final idHttp = _idOf(reqHttp);
      final idDio = _idOf(reqDio);
      expect(idHttp, isNotNull);
      expect(idDio, isNotNull);
      // The two requests carry distinct ids…
      expect(idHttp, isNot(equals(idDio)));
      // …and each response is attributed to its own request's id.
      expect(_idOf(resHttp), equals(idHttp));
      expect(_idOf(resDio), equals(idDio));

      // No pub line carrying the http id ever mentions the dio package, and vice
      // versa: the Zone kept each request's traffic on its own id.
      for (final line in lines.where((l) => l.contains('pub') && _idOf(l) == idHttp)) {
        expect(line, isNot(contains('/dio')));
      }
      for (final line in lines.where((l) => l.contains('pub') && _idOf(l) == idDio)) {
        expect(line, isNot(contains('/http')));
      }
    },
  );
}
