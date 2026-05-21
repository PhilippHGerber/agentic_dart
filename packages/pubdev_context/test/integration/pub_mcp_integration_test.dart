/// Integration tests for pubdev_context against the live pub.dev API.
///
/// NOT run by default — requires a live network connection.
/// Run with: dart test test/integration/
///
/// Tests spawn the real binary via `dart run` and communicate over stdio using
/// newline-delimited JSON-RPC, exactly as an MCP client would.
///
/// Test subjects use stable, well-known packages: http, path, dart_mcp.
/// These are safe to query without risk of false failures.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// ─── McpProcess ──────────────────────────────────────────────────────────────

/// Wraps a spawned `pubdev_context` process with typed send/receive helpers.
///
/// Messages are newline-delimited JSON. [send] writes a request and waits for
/// the matching response (matched by `id`). [notify] writes a notification
/// (no `id`, no response expected).
final class _McpProcess {
  _McpProcess._(this._process, this._responses);

  final Process _process;
  final Stream<Map<String, Object?>> _responses;

  int _nextId = 1;

  /// Spawns the binary as a subprocess via `dart run`.
  static Future<_McpProcess> start() async {
    final packageDir = Directory.current.path;
    final process = await Process.start(
      'dart',
      ['run', 'bin/pubdev_context.dart'],
      workingDirectory: packageDir,
    );

    // Drain stderr so the process doesn't block on a full pipe buffer.
    unawaited(process.stderr.drain<void>());

    final responses = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.isNotEmpty)
        .map((line) => jsonDecode(line) as Map<String, Object?>)
        .asBroadcastStream();

    return _McpProcess._(process, responses);
  }

  /// Sends [message] and returns the response whose `id` matches.
  Future<Map<String, Object?>> send(Map<String, Object?> message) {
    _process.stdin.writeln(jsonEncode(message));
    final id = message['id'];
    return _responses.firstWhere((r) => r['id'] == id);
  }

  /// Sends a notification (no `id`, no response expected).
  void notify(Map<String, Object?> message) {
    _process.stdin.writeln(jsonEncode(message));
  }

  /// Performs the MCP handshake: `initialize` + `initialized` notification.
  Future<Map<String, Object?>> handshake() async {
    final id = _nextId++;
    final result = await send({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'initialize',
      'params': {
        'protocolVersion': '2024-11-05',
        'capabilities': <String, Object?>{},
        'clientInfo': {'name': 'integration-test', 'version': '0.0.1'},
      },
    });
    notify({
      'jsonrpc': '2.0',
      'method': 'notifications/initialized',
      'params': {},
    });
    return result;
  }

  /// Sends a `tools/list` request and returns the result map.
  Future<Map<String, Object?>> listTools() async {
    final id = _nextId++;
    final response = await send({'jsonrpc': '2.0', 'id': id, 'method': 'tools/list'});
    return response['result']! as Map<String, Object?>;
  }

  /// Sends a `tools/call` request for [toolName] with [args].
  Future<Map<String, Object?>> callTool(
    String toolName,
    Map<String, Object?> args,
  ) async {
    final id = _nextId++;
    final response = await send({
      'jsonrpc': '2.0',
      'id': id,
      'method': 'tools/call',
      'params': {'name': toolName, 'arguments': args},
    });
    return response['result']! as Map<String, Object?>;
  }

  /// Closes stdin and waits for the process to exit, killing it after 5 s.
  Future<int> close() async {
    await _process.stdin.close();
    return _process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);
        return _process.exitCode;
      },
    );
  }
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Decodes the first content item of a `tools/call` result as a JSON value.
Object? _content(_McpProcess _, Map<String, Object?> result) {
  final content = result['content']! as List<Object?>;
  final first = content.first! as Map<String, Object?>;
  return jsonDecode(first['text']! as String);
}

/// Returns the raw text from the first content item of a `tools/call` result.
String _text(Map<String, Object?> result) {
  final content = result['content']! as List<Object?>;
  final first = content.first! as Map<String, Object?>;
  return first['text']! as String;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

void main() {
  late _McpProcess mcp;

  setUpAll(() async {
    mcp = await _McpProcess.start();
    await mcp.handshake();
  });

  tearDownAll(() async {
    await mcp.close();
  });

  // ─── Lifecycle ────────────────────────────────────────────────────────────────

  group('lifecycle', () {
    test(
      'initialize response contains the protocolVersion field',
      () async {
        final freshMcp = await _McpProcess.start();
        final response = await freshMcp.handshake();
        final result = response['result']! as Map<String, Object?>;
        expect(result, contains('protocolVersion'));
        await freshMcp.close();
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test(
      'initialize response advertises the tools capability',
      () async {
        final freshMcp = await _McpProcess.start();
        final response = await freshMcp.handshake();
        final result = response['result']! as Map<String, Object?>;
        final caps = result['capabilities']! as Map<String, Object?>;
        expect(caps, contains('tools'));
        await freshMcp.close();
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );

    test('process exits cleanly after stdin closes', () async {
      final freshMcp = await _McpProcess.start();
      await freshMcp.handshake();
      final exitCode = await freshMcp.close().timeout(const Duration(seconds: 5));
      expect(exitCode, equals(0));
    }, timeout: const Timeout(Duration(seconds: 15)));
  });

  // ─── tools/list ───────────────────────────────────────────────────────────────

  group('tools/list', () {
    late List<String> toolNames;

    setUpAll(() async {
      final result = await mcp.listTools();
      toolNames = (result['tools']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((t) => t['name']! as String)
          .toList();
    });

    test('includes search_packages', () {
      expect(toolNames, contains('search_packages'));
    });

    test('includes get_package', () {
      expect(toolNames, contains('get_package'));
    });

    test('includes get_changelog', () {
      expect(toolNames, contains('get_changelog'));
    });

    test('includes compare_packages', () {
      expect(toolNames, contains('compare_packages'));
    });

    test('includes get_symbol_documentation', () {
      expect(toolNames, contains('get_symbol_documentation'));
    });
  });

  // ─── search_packages ─────────────────────────────────────────────────────────

  group('search_packages', () {
    late List<Object?> results;

    setUpAll(() async {
      final result = await mcp.callTool('search_packages', {'query': 'http'});
      results = _content(mcp, result)! as List<Object?>;
    });

    test('returns a non-empty list', () {
      expect(results, isNotEmpty);
    });

    test('returns objects with a name field', () {
      final first = results.first! as Map<String, Object?>;
      expect(first, contains('name'));
    });

    test('returns objects with a pubPoints field', () {
      final first = results.first! as Map<String, Object?>;
      expect(first, contains('pubPoints'));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ─── get_package ─────────────────────────────────────────────────────────────

  group('get_package', () {
    late Map<String, Object?> detail;

    setUpAll(() async {
      final result = await mcp.callTool('get_package', {'name': 'path'});
      detail = _content(mcp, result)! as Map<String, Object?>;
    });

    test('returns the correct package name', () {
      expect(detail['name'], equals('path'));
    });

    test('returns a non-empty version string', () {
      expect(detail['version'], isA<String>());
      expect(detail['version']! as String, isNotEmpty);
    });

    test('returns a pubPoints score', () {
      expect(detail['pubPoints'], isA<int>());
    });

    test('returns sdkConstraints with a dart field', () {
      final constraints = detail['sdkConstraints']! as Map<String, Object?>;
      expect(constraints, contains('dart'));
    });

    test('result is not an error', () {
      expect(detail, isNot(contains('error')));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ─── get_changelog ────────────────────────────────────────────────────────────

  group('get_changelog', () {
    late List<Object?> entries;

    setUpAll(() async {
      final result = await mcp.callTool('get_changelog', {'name': 'path'});
      entries = _content(mcp, result)! as List<Object?>;
    });

    test('returns a non-empty list of entries', () {
      expect(entries, isNotEmpty);
    });

    test('each entry has a version field', () {
      final first = entries.first! as Map<String, Object?>;
      expect(first, contains('version'));
    });

    test('each entry has a breaking field', () {
      final first = entries.first! as Map<String, Object?>;
      expect(first, contains('breaking'));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ─── get_symbol_documentation ────────────────────────────────────────────────

  group('get_symbol_documentation', () {
    late Map<String, Object?> result;
    late String text;

    setUpAll(() async {
      result = await mcp.callTool('get_symbol_documentation', {
        'package': 'http',
        'href': 'http/Client-class.html',
      });
      text = _text(result);
    });

    test('result is not an error', () {
      expect(result['isError'], isNot(true));
    });

    test('returns non-empty text content', () {
      expect(text, isNotEmpty);
    });

    test('strips HTML tags from the returned content', () {
      expect(text, isNot(contains('<html')));
      expect(text, isNot(contains('<body')));
    });

    test('contains recognisable symbol content', () {
      expect(text, contains('Client'));
    });
  }, timeout: const Timeout(Duration(seconds: 30)));

  // ─── compare_packages ────────────────────────────────────────────────────────

  group('compare_packages', () {
    late Map<String, Object?> payload;
    late Duration elapsed;

    setUpAll(() async {
      final start = DateTime.now();
      final result = await mcp.callTool('compare_packages', {
        'names': ['http', 'path', 'dart_mcp'],
      });
      elapsed = DateTime.now().difference(start);
      payload = _content(mcp, result)! as Map<String, Object?>;
    });

    test('result is not an error', () {
      expect(payload, isNot(contains('error')));
    });

    test('packages list contains all three requested packages', () {
      expect(payload['packages'], containsAll(['http', 'path', 'dart_mcp']));
    });

    test('errors map is empty when all packages succeed', () {
      expect(payload['errors'], equals({}));
    });

    test('matrix contains the likes field', () {
      final matrix = payload['matrix']! as Map<String, Object?>;
      expect(matrix, contains('likes'));
    });

    test('matrix contains the sdkConstraints.dart field', () {
      final matrix = payload['matrix']! as Map<String, Object?>;
      expect(matrix, contains('sdkConstraints.dart'));
    });

    test('total wall-clock time is at least 200 ms for 3-package comparison', () {
      expect(elapsed.inMilliseconds, greaterThanOrEqualTo(200));
    });
  }, timeout: const Timeout(Duration(seconds: 60)));
}
