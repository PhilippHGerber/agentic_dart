/// Unit tests for [LlmBoundaryTracer]: the inbound/result lines it writes, the
/// Correlation Id it shares between them, and the `Zone` it enters so deeper
/// code can read that id. Assertions target the bytes written through a
/// recording sink.
library;

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/trace/llm_boundary.dart';
import 'package:dart_pubdev_mcp/src/trace/wire_trace.dart';
import 'package:test/test.dart';

/// A [WireTraceSink] that records every written line in memory.
final class _RecordingSink implements WireTraceSink {
  final List<String> lines = <String>[];

  @override
  void writeLine(String line) => lines.add(line);

  @override
  void close() {}
}

void main() {
  late _RecordingSink sink;
  late WireTrace trace;
  late LlmBoundaryTracer tracer;

  setUp(() {
    sink = _RecordingSink();
    trace = WireTrace.withSink(
      sink,
      serverVersion: '0.0.0-test',
      maxPreviewBytes: 2048,
      concurrency: 5,
      cacheDir: '/tmp/cache',
      clock: () => DateTime(2026, 7, 9, 14, 3, 11, 204),
    );
    tracer = LlmBoundaryTracer(trace);
  });

  String joined() => sink.lines.join('\n');

  group('wrapTool', () {
    test('writes an inbound line with full args and an ok result line sharing one id', () async {
      final wrapped = tracer.wrapTool(
        (request) async => CallToolResult(content: [TextContent(text: '[{"name":"http"}]')]),
      );

      await wrapped(
        CallToolRequest(
          name: 'search_packages',
          arguments: {'query': 'http client', 'limit': 5},
        ),
      );

      expect(
        sink.lines,
        contains('14:03:11.204  #001  ← LLM   tools/call  search_packages'),
      );
      expect(
        sink.lines,
        contains('                       args: {"query":"http client","limit":5}'),
      );
      // Result line shares the same #001 id and reports ok + a body preview.
      expect(
        sink.lines.any(
          (l) => l.contains('#001  → LLM   result  search_packages   ok'),
        ),
        isTrue,
      );
      expect(sink.lines, contains('                       body: [{"name":"http"}]'));
    });

    test('runs the handler inside a Zone carrying the Correlation Id', () async {
      String? seenInsideHandler;
      final wrapped = tracer.wrapTool((request) async {
        seenInsideHandler = currentCorrelationId();
        return CallToolResult(content: [TextContent(text: 'ok')]);
      });

      await wrapped(CallToolRequest(name: 'get_package'));

      expect(seenInsideHandler, equals('#001'));
      // Outside any wrapped call there is no id on the zone.
      expect(currentCorrelationId(), isNull);
    });

    test('renders an error result with its ERROR code and error preview', () async {
      final wrapped = tracer.wrapTool(
        (request) async => CallToolResult(
          isError: true,
          content: [
            TextContent(
              text: '{"error":{"code":"PACKAGE_NOT_FOUND","message":"nope"}}',
            ),
          ],
        ),
      );

      await wrapped(CallToolRequest(name: 'get_package', arguments: {'package': 'htp'}));

      expect(
        sink.lines.any(
          (l) => l.contains(
            '#001  → LLM   result  get_package   ERROR PACKAGE_NOT_FOUND',
          ),
        ),
        isTrue,
      );
      expect(
        sink.lines,
        contains(
          '                       error: {"error":{"code":"PACKAGE_NOT_FOUND","message":"nope"}}',
        ),
      );
      // An error result carries no body: continuation.
      expect(joined().contains('body:'), isFalse);
    });

    test('allocates a fresh monotonic id per call', () async {
      final wrapped = tracer.wrapTool(
        (request) async => CallToolResult(content: [TextContent(text: 'x')]),
      );

      await wrapped(CallToolRequest(name: 'search_packages'));
      await wrapped(CallToolRequest(name: 'search_packages'));

      expect(joined(), contains('#001  ← LLM'));
      expect(joined(), contains('#002  ← LLM'));
    });
  });

  group('wrapResource', () {
    test('traces a read with the URI as the name and no args line', () async {
      final wrapped = tracer.wrapResource(
        (request) async => ReadResourceResult(
          contents: [
            TextResourceContents(
              uri: request.uri,
              text: '# http\nA composable HTTP client.',
              mimeType: 'text/markdown',
            ),
          ],
        ),
      );

      await wrapped(ReadResourceRequest(uri: 'pub://package/http/readme'));

      expect(
        sink.lines,
        contains(
          '14:03:11.204  #001  ← LLM   resources/read  pub://package/http/readme',
        ),
      );
      // No args continuation for a resource read.
      expect(joined().contains('args:'), isFalse);
      expect(
        sink.lines.any(
          (l) => l.contains(
            '#001  → LLM   result  pub://package/http/readme   ok',
          ),
        ),
        isTrue,
      );
    });

    test('propagates the Correlation Id into the handler zone', () async {
      String? seen;
      final wrapped = tracer.wrapResource((request) async {
        seen = currentCorrelationId();
        return ReadResourceResult(
          contents: [TextResourceContents(uri: request.uri, text: 'x')],
        );
      });

      await wrapped(ReadResourceRequest(uri: 'pub://package/http/readme'));

      expect(seen, equals('#001'));
    });

    test('renders a resource error body as an ERROR result', () async {
      final wrapped = tracer.wrapResource(
        (request) async => ReadResourceResult(
          contents: [
            TextResourceContents(
              uri: request.uri,
              text: '{"error":{"code":"PACKAGE_NOT_FOUND","message":"nope"}}',
              mimeType: 'application/json',
            ),
          ],
        ),
      );

      await wrapped(ReadResourceRequest(uri: 'pub://package/htp/readme'));

      expect(
        sink.lines.any(
          (l) => l.contains('ERROR PACKAGE_NOT_FOUND'),
        ),
        isTrue,
      );
    });

    test('logs no result line when the handler declines with null', () async {
      final wrapped = tracer.wrapResource((request) async => null);

      final result = await wrapped(ReadResourceRequest(uri: 'pub://other'));

      expect(result, isNull);
      expect(joined().contains('→ LLM   result'), isFalse);
    });
  });
}
