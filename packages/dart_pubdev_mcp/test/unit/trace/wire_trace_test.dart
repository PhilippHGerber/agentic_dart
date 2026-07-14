/// Unit tests for [WireTrace] (Seam 1): file lifecycle, correlation ids,
/// preview truncation, per-event line formatting, retention, and best-effort
/// robustness. Assertions target the bytes that land in the trace file.
library;

import 'dart:io';

import 'package:dart_pubdev_mcp/src/trace/wire_trace.dart';
import 'package:test/test.dart';

/// A [WireTraceSink] that records lines in memory and can be told to throw on a
/// chosen write, to exercise the mid-session failure path.
final class _RecordingSink implements WireTraceSink {
  _RecordingSink({this.throwOnWrite});

  final int? throwOnWrite;
  final List<String> lines = <String>[];
  int closeCount = 0;
  int _writes = 0;

  @override
  void writeLine(String line) {
    _writes++;
    if (throwOnWrite != null && _writes == throwOnWrite) {
      throw const FileSystemException('disk full');
    }
    lines.add(line);
  }

  @override
  void close() => closeCount++;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_wire_trace_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  WireTrace openTrace({
    int maxPreviewBytes = 2048,
    int pid = 4242,
    DateTime Function()? clock,
    void Function(String)? onWarning,
  }) => WireTrace.open(
    directoryPath: tempDir.path,
    serverVersion: '0.0.0-test',
    maxPreviewBytes: maxPreviewBytes,
    concurrency: 5,
    cacheDir: '~/.cache/dart_pubdev_mcp',
    pid: pid,
    clock: clock,
    onWarning: onWarning,
  );

  List<String> sessionFiles() =>
      tempDir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.startsWith('wire-trace-') && n.endsWith('.log'))
          .toList()
        ..sort();

  String soleFileContent() {
    final files = sessionFiles();
    expect(files, hasLength(1));
    return File('${tempDir.path}${Platform.pathSeparator}${files.single}').readAsStringSync();
  }

  group('session file and header', () {
    test('creates a single per-session file named by timestamp and pid', () {
      openTrace(
        clock: () => DateTime(2026, 7, 9, 14, 3, 10, 981),
        pid: 48213,
      ).close();

      expect(sessionFiles(), ['wire-trace-20260709-140310-981-pid48213.log']);
    });

    test('writes the session-header block as the first thing in the file', () {
      openTrace(
        clock: () => DateTime(2026, 7, 9, 14, 3, 10, 981),
        pid: 48213,
      ).close();

      final lines = soleFileContent().split('\n');
      final bar = '═' * 72;
      expect(lines[0], bar);
      expect(lines[1], ' Wire Trace — dart-pubdev-explorer 0.0.0-test');
      expect(lines[2], ' session started 2026-07-09 14:03:10.981   pid 48213');
      expect(
        lines[3],
        ' config: max-preview=2048B  concurrency=5  cache=~/.cache/dart_pubdev_mcp',
      );
      expect(lines[4], bar);
      expect(lines[5], '');
    });

    test('each line is flushed immediately (readable before close)', () {
      var now = DateTime(2026, 7, 9, 14, 3, 11, 204);
      final trace = openTrace(clock: () => now);

      now = DateTime(2026, 7, 9, 14, 3, 11, 500);
      trace.logInboundCall(
        id: '#001',
        method: 'tools/call',
        name: 'search_packages',
        argsJson: '{"query":"http"}',
      );

      // File is readable and contains the line before close() is ever called.
      final content = soleFileContent();
      expect(content, contains('#001  ← LLM   tools/call  search_packages'));

      trace.close();
    });
  });

  group('correlation ids', () {
    test('are monotonic, zero-padded, and unique across many allocations', () {
      final trace = openTrace();
      final ids = <String>{};
      String? previous;
      for (var i = 0; i < 2500; i++) {
        final id = trace.nextCorrelationId();
        expect(ids.add(id), isTrue, reason: 'duplicate id $id');
        if (previous != null) {
          expect(id.compareTo(previous), isNot(0));
        }
        previous = id;
      }
      trace.close();

      expect(ids.first, '#001');
      expect(ids.contains('#002'), isTrue);
      expect(ids.contains('#010'), isTrue);
      expect(ids.contains('#100'), isTrue);
      expect(ids.contains('#1000'), isTrue);
    });
  });

  group('formatBodyPreview', () {
    test('returns text whole and single-lined when under the cap', () {
      expect(
        formatBodyPreview('{"a":1}', maxPreviewBytes: 2048),
        '{"a":1}',
      );
      expect(
        formatBodyPreview('line1\nline2', maxPreviewBytes: 2048),
        'line1 line2',
      );
    });

    test('truncates over-cap text with an annotation and the true total', () {
      final text = 'x' * 5000;
      final preview = formatBodyPreview(text, maxPreviewBytes: 10);

      expect(preview, isNotNull);
      final value = preview ?? '';
      expect(value, startsWith('xxxxxxxxxx…'));
      expect(value, contains('(truncated, '));
      expect(value, endsWith('total)'));
      // 5000 bytes -> 4.9 KB.
      expect(value, contains('4.9 KB total'));
    });

    test('cap of 0 is metadata-only (no body)', () {
      expect(formatBodyPreview('anything', maxPreviewBytes: 0), isNull);
    });

    test('a tarball payload is metadata-only regardless of cap', () {
      expect(
        formatBodyPreview('binary-ish', maxPreviewBytes: 2048, isTarball: true),
        isNull,
      );
    });

    test('never splits a multi-byte code point when truncating', () {
      // '€' is three UTF-8 bytes; a 4-byte cap fits exactly one.
      final preview = formatBodyPreview('€€€', maxPreviewBytes: 4);
      expect(preview, startsWith('€…'));
    });

    test('humanBytes renders compact sizes', () {
      expect(humanBytes(940), '940 B');
      expect(humanBytes(4198), '4.1 KB');
      expect(humanBytes(2 * 1024 * 1024 + 300 * 1024), '2.3 MB');
    });
  });

  group('event formatting', () {
    late WireTrace trace;
    late DateTime now;

    setUp(() {
      now = DateTime(2026, 7, 9, 14, 3, 11, 204);
      trace = openTrace(clock: () => now);
    });

    tearDown(() => trace.close());

    List<String> body() => soleFileContent().split('\n');

    test('inbound LLM call renders direction marker and args continuation', () {
      trace.logInboundCall(
        id: '#001',
        method: 'tools/call',
        name: 'search_packages',
        argsJson: '{"query":"http client","limit":5}',
      );

      final lines = body();
      expect(
        lines,
        contains('14:03:11.204  #001  ← LLM   tools/call  search_packages'),
      );
      expect(
        lines,
        contains('                       args: {"query":"http client","limit":5}'),
      );
    });

    test('separates inbound calls with a blank line but not the first', () {
      trace
        ..logInboundCall(id: '#001', method: 'tools/call', name: 'search_packages')
        ..logInboundCall(id: '#002', method: 'tools/call', name: 'get_package');

      final lines = body();
      final first = lines.indexWhere((l) => l.contains('#001  ← LLM'));
      final second = lines.indexWhere((l) => l.contains('#002  ← LLM'));

      // The first inbound call adds no blank line of its own: it sits directly
      // after the header's single trailing blank line, with header content (the
      // rule bar) right above that — i.e. exactly one blank, not two.
      expect(lines[first - 1], isEmpty, reason: "header's trailing blank");
      expect(lines[first - 2], isNot(isEmpty), reason: 'no extra wrapper blank');
      // The second inbound call is immediately preceded by a wrapper blank line,
      // with the first request's content above it.
      expect(lines[second - 1], isEmpty);
      expect(lines[second - 2], isNot(isEmpty));
    });

    test('outbound pub request renders → marker and cache-miss context', () {
      trace.logRequest(
        id: '#001',
        httpMethod: 'GET',
        path: '/api/search?q=http+client',
        context: 'cache miss',
      );

      expect(
        body(),
        contains('14:03:11.204  #001    → pub  GET /api/search?q=http+client  [cache miss]'),
      );
    });

    test('pub response renders status, latency, size, type and body preview', () {
      trace.logResponse(
        id: '#001',
        status: 200,
        path: '/api/search',
        latency: const Duration(milliseconds: 312),
        sizeBytes: 4198,
        contentType: 'JSON',
        preview: '{"packages":[…]}',
      );

      final lines = body();
      expect(
        lines,
        contains('14:03:11.204  #001    ← pub  200 /api/search  (312 ms, 4.1 KB JSON)'),
      );
      expect(lines, contains('                       body: {"packages":[…]}'));
    });

    test('HTML response renders the HTML → md sizes and the markdown preview', () {
      trace.logResponse(
        id: '#001',
        status: 200,
        path: '/packages/foo/changelog',
        latency: const Duration(milliseconds: 312),
        sizeBytes: 43008,
        markdownSizeBytes: 6240,
        preview: '## 1.0.0 - fixes',
      );

      final lines = body();
      expect(
        lines,
        contains(
          '14:03:11.204  #001    ← pub  200 /packages/foo/changelog  '
          '(312 ms, 42.0 KB HTML → 6.1 KB md)',
        ),
      );
      expect(lines, contains('                       body: ## 1.0.0 - fixes'));
      // The raw HTML is never dumped: only the markdown preview appears.
      expect(lines.any((l) => l.contains('<')), isFalse);
    });

    test('tarball response renders size and file count as metadata only', () {
      trace.logResponse(
        id: '#001',
        status: 200,
        path: '/api/packages/foo/versions/1.0.0/archive.tar.gz',
        latency: const Duration(milliseconds: 400),
        sizeBytes: 1258291,
        contentType: 'tar.gz',
        fileCount: 42,
      );

      final lines = body();
      expect(
        lines,
        contains(
          '14:03:11.204  #001    ← pub  200 '
          '/api/packages/foo/versions/1.0.0/archive.tar.gz  '
          '(400 ms, 1.2 MB tar.gz, 42 files)',
        ),
      );
      // A tarball is metadata only — no body/archive content ever appears.
      expect(lines.any((l) => l.contains('body:')), isFalse);
    });

    test('a single-file tarball uses the singular "file"', () {
      trace.logResponse(
        id: '#001',
        status: 200,
        path: '/api/packages/foo/versions/1.0.0/archive.tar.gz',
        latency: const Duration(milliseconds: 10),
        sizeBytes: 512,
        contentType: 'tar.gz',
        fileCount: 1,
      );

      expect(body().any((l) => l.contains('1 file)')), isTrue);
    });

    test('pub response without a body omits the body continuation line', () {
      trace.logResponse(
        id: '#019',
        status: 404,
        path: '/api/packages/htp',
        latency: const Duration(milliseconds: 319),
      );

      final lines = body();
      expect(lines, contains('14:03:11.204  #019    ← pub  404 /api/packages/htp  (319 ms)'));
      expect(lines.any((l) => l.contains('body:')), isFalse);
    });

    test('ok result renders summary/duration/size and body preview', () {
      trace.logResult(
        id: '#001',
        name: 'search_packages',
        duration: const Duration(milliseconds: 806),
        isError: false,
        summary: '5 results',
        sizeBytes: 6501,
        bodyPreview: '[{"name":"http"}]',
      );

      final lines = body();
      expect(
        lines,
        contains(
          '14:03:11.204  #001  → LLM   result  search_packages   ok   '
          '(5 results, 806 ms, 6.3 KB)',
        ),
      );
      expect(lines, contains('                       body: [{"name":"http"}]'));
    });

    test('error result renders ERROR code and error continuation', () {
      trace.logResult(
        id: '#019',
        name: 'get_package',
        duration: const Duration(milliseconds: 321),
        isError: true,
        errorCode: 'PACKAGE_NOT_FOUND',
        errorPreview: '{"code":"PACKAGE_NOT_FOUND"}',
      );

      final lines = body();
      expect(
        lines,
        contains(
          '14:03:11.204  #019  → LLM   result  get_package   '
          'ERROR PACKAGE_NOT_FOUND  (321 ms)',
        ),
      );
      expect(lines, contains('                       error: {"code":"PACKAGE_NOT_FOUND"}'));
    });

    test('retry renders the ⚠ marker, attempt count and backoff', () {
      trace.logRetry(
        id: '#055',
        status: 503,
        path: '/api/search',
        latency: const Duration(milliseconds: 318),
        attempt: 1,
        maxAttempts: 3,
        backoff: const Duration(milliseconds: 500),
      );

      expect(
        body(),
        contains(
          '14:03:11.204  #055    ⚠ pub  503 /api/search  '
          '(318 ms) — retry 1/3 in 500 ms',
        ),
      );
    });

    test('retry request line carries a [retry N] context', () {
      trace.logRequest(
        id: '#055',
        httpMethod: 'GET',
        path: '/api/search?q=foo',
        context: 'retry 1',
      );

      expect(
        body(),
        contains('14:03:11.204  #055    → pub  GET /api/search?q=foo  [retry 1]'),
      );
    });

    test('cache hit renders the ⚡ marker, key and age', () {
      trace.logCacheHit(
        id: '#002',
        key: 'get_package:http',
        age: const Duration(seconds: 12),
      );

      expect(
        body(),
        contains(
          '14:03:11.204  #002    ⚡ cache hit  get_package:http   '
          '(age 12s, no pub.dev call)',
        ),
      );
    });
  });

  group('retention', () {
    test('keeps the newest 10 session files and deletes the oldest', () {
      // Create 11 sessions with strictly increasing timestamps so filenames
      // sort chronologically.
      for (var i = 0; i < 11; i++) {
        openTrace(
          clock: () => DateTime(2026, 7, 9, 14, 0, i),
          pid: 1000 + i,
        ).close();
      }

      final files = sessionFiles();
      expect(files, hasLength(10));
      // The very first session (second 0) must have been pruned.
      expect(files.any((n) => n.contains('-140000-000-pid1000.log')), isFalse);
      // The newest session (second 10) is retained.
      expect(files.any((n) => n.contains('-140010-000-pid1010.log')), isTrue);
    });
  });

  group('best-effort robustness', () {
    test('an unwritable directory yields one warning and a disabled no-op', () {
      // Point at a path whose parent is a file, so createSync fails.
      final blocker = File('${tempDir.path}${Platform.pathSeparator}blocker')
        ..writeAsStringSync('x');
      final warnings = <String>[];

      final trace = WireTrace.open(
        directoryPath: '${blocker.path}${Platform.pathSeparator}nested',
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 2048,
        concurrency: 5,
        cacheDir: '/tmp/cache',
        onWarning: warnings.add,
      );

      expect(warnings, hasLength(1));
      expect(warnings.single, contains('Wire Trace disabled'));
      expect(trace.isEnabled, isFalse);

      // Every method is a safe no-op and nothing throws.
      expect(
        () {
          trace
            ..logInboundCall(id: '#001', method: 'tools/call', name: 'x', argsJson: '{}')
            ..logCacheHit(id: '#001', key: 'k', age: Duration.zero)
            ..close();
        },
        returnsNormally,
      );
    });

    test('a mid-session write failure is swallowed and disables tracing', () {
      // The header is 6 writes; fail on the 7th (the first event line).
      final sink = _RecordingSink(throwOnWrite: 7);
      final trace = WireTrace.withSink(
        sink,
        serverVersion: '0.0.0-test',
        maxPreviewBytes: 2048,
        concurrency: 5,
        cacheDir: '/tmp/cache',
      );

      expect(trace.isEnabled, isTrue);

      expect(
        () => trace.logInboundCall(
          id: '#001',
          method: 'tools/call',
          name: 'search_packages',
          argsJson: '{}',
        ),
        returnsNormally,
      );

      expect(trace.isEnabled, isFalse);
      expect(sink.closeCount, greaterThanOrEqualTo(1));

      // Subsequent calls stay no-ops and write nothing further.
      final linesAfterFailure = sink.lines.length;
      trace.logCacheHit(id: '#002', key: 'k', age: Duration.zero);
      expect(sink.lines, hasLength(linesAfterFailure));
    });
  });
}
