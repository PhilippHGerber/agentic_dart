/// Shared test-only wiring for the pub.dev HTTP surface.
///
/// A thin builder ([TestStack]) plus plain stub helpers — no assertion or
/// decoding magic. The MCP request/response shapes under test stay visible
/// in each test file; this module only removes duplicated plumbing.
library;

import 'dart:io';

import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/data/pub_client.dart';
import 'package:dart_pubdev_mcp/src/data/sdk_client.dart';
import 'package:dart_pubdev_mcp/src/trace/wire_trace.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart' show predicate;

/// A mocktail double for [http.Client].
///
/// Stub it with [stubUrl] for simple `GET`-by-URL-fragment cases, or with a
/// direct `when(() => mock.get(...))` / `when(() => mock.send(...))` call for
/// anything more specific (tarball streams, header assertions, …).
class MockHttpClient extends Mock implements http.Client {}

/// A [RetryPolicy] that never delays — every unit test's retry attempts
/// resolve instantly instead of waiting out real backoff.
RetryPolicy get instantRetryPolicy => RetryPolicy(delay: (_) async {});

/// Reads a fixture file from `test/fixtures/`.
String readFixture(String name) => File('test/fixtures/$name').readAsStringSync();

/// A 200 OK [http.Response] carrying [body].
http.Response ok(String body) => http.Response(body, 200);

/// A 404 Not Found [http.Response].
http.Response notFound() => http.Response('Not Found', 404);

/// Stubs [mock]'s `GET` handler to return [response] for any request whose
/// URL contains [urlFragment].
///
/// mocktail resolves overlapping stubs LIFO — the most recently registered
/// matching stub wins. When two fragments overlap (e.g. the bare
/// `/api/packages/http` and the more specific `/api/packages/http/score`),
/// register the more specific one *last* so it isn't shadowed by the
/// broader stub.
void stubUrl({
  required MockHttpClient mock,
  required String urlFragment,
  required http.Response response,
}) {
  when(
    () => mock.get(
      any(that: predicate<Uri>((Uri u) => u.toString().contains(urlFragment))),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => response);
}

/// Registers the `Uri` and `http.Request` fallback values mocktail needs for
/// `any()` matchers on [MockHttpClient.get]/`.send`.
///
/// A free function rather than a [TestStack] method — [TestStack] has an
/// `http` field, which would shadow this file's `http` import prefix inside
/// any instance method that needs `http.Request(...)`.
void _registerHttpFallbacks() {
  registerFallbackValue(Uri.parse('https://pub.dev'));
  registerFallbackValue(http.Request('GET', Uri.parse('https://pub.dev')));
}

/// Wires a mock `http.Client` → real [PubDevClient] (instant retry) → real
/// [CacheRegistry] — the stack most tool-handler and resource-handler tests
/// build. `clock` is forwarded to [CacheRegistry] for TTL control; omit it
/// for wall-clock time. `trace` is forwarded to both [PubDevClient] and
/// [CacheRegistry] — [TestStack] does not construct the [WireTrace] itself
/// since its directory is per-test-temp; callers that need tracing build
/// their own and pass it in.
class TestStack {
  TestStack({DateTime Function()? clock, WireTrace? trace}) : http = MockHttpClient() {
    _registerHttpFallbacks();
    client = PubDevClient(httpClient: http, retryPolicy: instantRetryPolicy, trace: trace);
    sdkClient = SdkClient(httpClient: http, retryPolicy: instantRetryPolicy);
    caches = CacheRegistry(client: client, sdkClient: sdkClient, clock: clock, trace: trace);
  }

  /// The mock HTTP client backing [client] and [sdkClient]. Stub it with
  /// [stubUrl] or a direct `when(...)` call before exercising a handler built
  /// on [caches].
  final MockHttpClient http;

  /// The real [PubDevClient] wired to [http].
  late final PubDevClient client;

  /// The real [SdkClient] wired to [http].
  late final SdkClient sdkClient;

  /// The real [CacheRegistry] wired to [client] and [sdkClient].
  late final CacheRegistry caches;

  /// Closes [client]'s and [sdkClient]'s underlying HTTP connections.
  void close() {
    client.close();
    sdkClient.close();
  }
}
