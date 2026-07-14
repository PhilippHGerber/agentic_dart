/// Unit tests for [PubMcpConfig] and [LogLevel].
library;

import 'dart:io';

import 'package:dart_pubdev_mcp/src/config/config.dart';
import 'package:test/test.dart';

void main() {
  group('LogLevel.parse', () {
    test('returns debug for "debug"', () {
      expect(LogLevel.parse('debug'), equals(LogLevel.debug));
    });

    test('returns info for "info"', () {
      expect(LogLevel.parse('info'), equals(LogLevel.info));
    });

    test('returns warning for "warning"', () {
      expect(LogLevel.parse('warning'), equals(LogLevel.warning));
    });

    test('returns error for "error"', () {
      expect(LogLevel.parse('error'), equals(LogLevel.error));
    });

    test('is case-insensitive', () {
      expect(LogLevel.parse('DEBUG'), equals(LogLevel.debug));
    });

    test('throws FormatException for an unknown value', () {
      expect(() => LogLevel.parse('verbose'), throwsFormatException);
    });
  });

  group('PubMcpConfig defaults', () {
    test('logLevel defaults to warning when no flag or env var is set', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.logLevel, equals(LogLevel.warning));
    });

    test('cacheDir falls back to an absolute temp-directory path when HOME is unavailable', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      // Verify absolute path: starts with the system temp directory and ends
      // with the expected leaf name. The exact separator is platform-specific.
      expect(config.cacheDir, startsWith(Directory.systemTemp.path));
      expect(config.cacheDir, endsWith('dart_pubdev_mcp'));
    });

    test('maxCacheSizeBytes defaults to 500 MiB', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.maxCacheSizeBytes, equals(kDefaultMaxCacheSizeBytes));
    });

    test('maxConcurrentRequests defaults to 5', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.maxConcurrentRequests, equals(kDefaultMaxConcurrentRequests));
      expect(config.maxConcurrentRequests, equals(5));
    });

    test('wireTrace defaults to off', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.wireTrace, isFalse);
    });

    test('wireTraceDir defaults to a wire-trace subdirectory of the cache dir', () {
      final config = PubMcpConfig.fromArguments(
        ['--cache-dir', '/tmp/cache'],
        environment: {},
      );
      expect(config.wireTraceDir, equals('/tmp/cache/wire-trace'));
    });

    test('wireTraceMaxPreview defaults to 2048', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.wireTraceMaxPreview, equals(kDefaultWireTraceMaxPreview));
      expect(config.wireTraceMaxPreview, equals(2048));
    });
  });

  group('PubMcpConfig CLI flags', () {
    test('--log-level debug sets logLevel to debug', () {
      final config = PubMcpConfig.fromArguments(
        ['--log-level', 'debug'],
        environment: {},
      );
      expect(config.logLevel, equals(LogLevel.debug));
    });

    test('--log-level=info sets logLevel to info', () {
      final config = PubMcpConfig.fromArguments(
        ['--log-level=info'],
        environment: {},
      );
      expect(config.logLevel, equals(LogLevel.info));
    });

    test('--cache-dir /tmp/cache sets cacheDir', () {
      final config = PubMcpConfig.fromArguments(
        ['--cache-dir', '/tmp/cache'],
        environment: {},
      );
      expect(config.cacheDir, equals('/tmp/cache'));
    });

    test('--cache-dir=/tmp/cache sets cacheDir', () {
      final config = PubMcpConfig.fromArguments(
        ['--cache-dir=/tmp/cache'],
        environment: {},
      );
      expect(config.cacheDir, equals('/tmp/cache'));
    });

    test('--max-cache-size 100MB sets maxCacheSizeBytes', () {
      final config = PubMcpConfig.fromArguments(
        ['--max-cache-size', '100MB'],
        environment: {},
      );
      expect(config.maxCacheSizeBytes, equals(100000000));
    });

    test('--max-cache-size=64MiB sets maxCacheSizeBytes', () {
      final config = PubMcpConfig.fromArguments(
        ['--max-cache-size=64MiB'],
        environment: {},
      );
      expect(config.maxCacheSizeBytes, equals(64 * 1024 * 1024));
    });

    test('--max-concurrent-requests 10 sets maxConcurrentRequests', () {
      final config = PubMcpConfig.fromArguments(
        ['--max-concurrent-requests', '10'],
        environment: {},
      );
      expect(config.maxConcurrentRequests, equals(10));
    });

    test('--max-concurrent-requests=3 sets maxConcurrentRequests', () {
      final config = PubMcpConfig.fromArguments(
        ['--max-concurrent-requests=3'],
        environment: {},
      );
      expect(config.maxConcurrentRequests, equals(3));
    });

    test('--max-concurrent-requests rejects zero', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--max-concurrent-requests=0'],
          environment: {},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('positive integer'),
          ),
        ),
      );
    });

    test('--max-concurrent-requests rejects non-numeric values', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--max-concurrent-requests=lots'],
          environment: {},
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('--wire-trace enables tracing as a bare presence flag', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace'],
        environment: {},
      );
      expect(config.wireTrace, isTrue);
    });

    test('--wire-trace=false disables tracing', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace=false'],
        environment: {},
      );
      expect(config.wireTrace, isFalse);
    });

    test('--wire-trace-dir /tmp/wt sets wireTraceDir', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace-dir', '/tmp/wt'],
        environment: {},
      );
      expect(config.wireTraceDir, equals('/tmp/wt'));
    });

    test('--wire-trace-dir=/tmp/wt sets wireTraceDir', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace-dir=/tmp/wt'],
        environment: {},
      );
      expect(config.wireTraceDir, equals('/tmp/wt'));
    });

    test('--wire-trace-max-preview 0 sets a metadata-only preview cap', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace-max-preview', '0'],
        environment: {},
      );
      expect(config.wireTraceMaxPreview, equals(0));
    });

    test('--wire-trace-max-preview=4096 sets wireTraceMaxPreview', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace-max-preview=4096'],
        environment: {},
      );
      expect(config.wireTraceMaxPreview, equals(4096));
    });

    test('--wire-trace-max-preview rejects negative values', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--wire-trace-max-preview=-1'],
          environment: {},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('non-negative'),
          ),
        ),
      );
    });

    test('--wire-trace-max-preview rejects non-numeric values', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--wire-trace-max-preview=lots'],
          environment: {},
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('PubMcpConfig environment variables', () {
    test('dart_pubdev_mcp_LOG_LEVEL=info sets logLevel to info when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'dart_pubdev_mcp_LOG_LEVEL': 'info'},
      );
      expect(config.logLevel, equals(LogLevel.info));
    });

    test('dart_pubdev_mcp_CACHE_DIR sets cacheDir when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'dart_pubdev_mcp_CACHE_DIR': '/env/cache'},
      );
      expect(config.cacheDir, equals('/env/cache'));
    });

    test('dart_pubdev_mcp_MAX_CACHE_SIZE sets maxCacheSizeBytes when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'dart_pubdev_mcp_MAX_CACHE_SIZE': '42MiB'},
      );
      expect(config.maxCacheSizeBytes, equals(42 * 1024 * 1024));
    });

    test(
      'dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS sets maxConcurrentRequests when no flag is present',
      () {
        final config = PubMcpConfig.fromArguments(
          [],
          environment: {'dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS': '8'},
        );
        expect(config.maxConcurrentRequests, equals(8));
      },
    );

    test('uses XDG_CACHE_HOME when cache dir is not explicitly set', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'XDG_CACHE_HOME': '/xdg/cache'},
      );
      expect(config.cacheDir, equals('/xdg/cache/dart_pubdev_mcp'));
    });

    test('falls back to HOME/.cache/dart_pubdev_mcp when XDG_CACHE_HOME is unset', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'HOME': '/home/tester'},
      );
      expect(config.cacheDir, equals('/home/tester/.cache/dart_pubdev_mcp'));
    });

    test('dart_pubdev_mcp_WIRE_TRACE=true enables tracing when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'dart_pubdev_mcp_WIRE_TRACE': 'true'},
      );
      expect(config.wireTrace, isTrue);
    });

    test('dart_pubdev_mcp_WIRE_TRACE_DIR sets wireTraceDir when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'dart_pubdev_mcp_WIRE_TRACE_DIR': '/env/wt'},
      );
      expect(config.wireTraceDir, equals('/env/wt'));
    });

    test(
      'dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW sets wireTraceMaxPreview when no flag is present',
      () {
        final config = PubMcpConfig.fromArguments(
          [],
          environment: {'dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW': '512'},
        );
        expect(config.wireTraceMaxPreview, equals(512));
      },
    );
  });

  group('PubMcpConfig precedence', () {
    test('--log-level flag overrides dart_pubdev_mcp_LOG_LEVEL env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--log-level', 'debug'],
        environment: {'dart_pubdev_mcp_LOG_LEVEL': 'info'},
      );
      expect(config.logLevel, equals(LogLevel.debug));
    });

    test('--cache-dir flag overrides dart_pubdev_mcp_CACHE_DIR env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--cache-dir', '/flag/cache'],
        environment: {'dart_pubdev_mcp_CACHE_DIR': '/env/cache'},
      );
      expect(config.cacheDir, equals('/flag/cache'));
    });

    test('--max-cache-size flag overrides dart_pubdev_mcp_MAX_CACHE_SIZE env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--max-cache-size', '10MiB'],
        environment: {'dart_pubdev_mcp_MAX_CACHE_SIZE': '1MiB'},
      );
      expect(config.maxCacheSizeBytes, equals(10 * 1024 * 1024));
    });

    test(
      '--max-concurrent-requests flag overrides dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS env var',
      () {
        final config = PubMcpConfig.fromArguments(
          ['--max-concurrent-requests', '12'],
          environment: {'dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS': '2'},
        );
        expect(config.maxConcurrentRequests, equals(12));
      },
    );

    test('--wire-trace=false flag overrides dart_pubdev_mcp_WIRE_TRACE env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace=false'],
        environment: {'dart_pubdev_mcp_WIRE_TRACE': 'true'},
      );
      expect(config.wireTrace, isFalse);
    });

    test('--wire-trace flag overrides dart_pubdev_mcp_WIRE_TRACE=false env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace'],
        environment: {'dart_pubdev_mcp_WIRE_TRACE': 'false'},
      );
      expect(config.wireTrace, isTrue);
    });

    test('--wire-trace-dir flag overrides dart_pubdev_mcp_WIRE_TRACE_DIR env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--wire-trace-dir', '/flag/wt'],
        environment: {'dart_pubdev_mcp_WIRE_TRACE_DIR': '/env/wt'},
      );
      expect(config.wireTraceDir, equals('/flag/wt'));
    });

    test(
      '--wire-trace-max-preview flag overrides dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW env var',
      () {
        final config = PubMcpConfig.fromArguments(
          ['--wire-trace-max-preview', '99'],
          environment: {'dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW': '11'},
        );
        expect(config.wireTraceMaxPreview, equals(99));
      },
    );
  });

  group('PubMcpConfig const constructor', () {
    test('const constructor has logLevel warning by default', () {
      const config = PubMcpConfig();
      expect(config.logLevel, equals(LogLevel.warning));
    });

    test('const constructor has default cacheDir', () {
      const config = PubMcpConfig();
      expect(config.cacheDir, equals('.cache/dart_pubdev_mcp'));
    });

    test('const constructor has default maxCacheSizeBytes', () {
      const config = PubMcpConfig();
      expect(config.maxCacheSizeBytes, equals(kDefaultMaxCacheSizeBytes));
    });

    test('const constructor has default maxConcurrentRequests', () {
      const config = PubMcpConfig();
      expect(config.maxConcurrentRequests, equals(kDefaultMaxConcurrentRequests));
    });

    test('const constructor accepts explicit values', () {
      const config = PubMcpConfig(
        logLevel: LogLevel.debug,
        cacheDir: '/cache',
        maxCacheSizeBytes: 123,
        maxConcurrentRequests: 7,
        wireTrace: true,
        wireTraceDir: '/wt',
        wireTraceMaxPreview: 64,
      );
      expect(config.logLevel, equals(LogLevel.debug));
      expect(config.cacheDir, equals('/cache'));
      expect(config.maxCacheSizeBytes, equals(123));
      expect(config.maxConcurrentRequests, equals(7));
      expect(config.wireTrace, isTrue);
      expect(config.wireTraceDir, equals('/wt'));
      expect(config.wireTraceMaxPreview, equals(64));
    });

    test('const constructor defaults wire trace off with a 2048-byte preview', () {
      const config = PubMcpConfig();
      expect(config.wireTrace, isFalse);
      expect(config.wireTraceMaxPreview, equals(kDefaultWireTraceMaxPreview));
    });
  });

  group('binary --version and --help', () {
    test('--version prints dart-pubdev-explorer and the current version, then exits 0', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--version'],
      );
      expect(result.exitCode, equals(0));
      expect(result.stdout, contains('dart-pubdev-explorer '));
    });

    test('--help prints usage summary and exits 0', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--help'],
      );
      expect(result.exitCode, equals(0));
      expect(result.stdout.toString(), contains('Usage:'));
      expect(result.stdout.toString(), contains('--max-cache-size'));
      expect(result.stdout.toString(), contains('--max-concurrent-requests'));
      expect(result.stdout.toString(), contains('--wire-trace'));
      expect(result.stdout.toString(), contains('--wire-trace-dir'));
      expect(result.stdout.toString(), contains('--wire-trace-max-preview'));
    });
  });

  group('binary bad-flag error handling', () {
    test('invalid --max-cache-size prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--max-cache-size=foo'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('Invalid cache size'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('invalid --log-level prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--log-level=verbose'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('Unknown log level'));
      expect(result.stderr.toString(), contains('--help'));
    });
  });

  group('PubMcpConfig bare flag without value', () {
    test('--log-level without value throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(['--log-level'], environment: {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--log-level'),
          ),
        ),
      );
    });

    test('--cache-dir without value throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(['--cache-dir'], environment: {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--cache-dir'),
          ),
        ),
      );
    });

    test('--max-cache-size without value throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(['--max-cache-size'], environment: {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--max-cache-size'),
          ),
        ),
      );
    });

    test('--max-concurrent-requests without value throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--max-concurrent-requests'],
          environment: {},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--max-concurrent-requests'),
          ),
        ),
      );
    });

    test('--wire-trace-dir without value throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(['--wire-trace-dir'], environment: {}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--wire-trace-dir'),
          ),
        ),
      );
    });

    test('--wire-trace-max-preview without value throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--wire-trace-max-preview'],
          environment: {},
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('--wire-trace-max-preview'),
          ),
        ),
      );
    });

    test('--log-level without value at end of multi-flag list throws FormatException', () {
      expect(
        () => PubMcpConfig.fromArguments(
          ['--cache-dir', '/tmp/cache', '--log-level'],
          environment: {},
        ),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('binary bare-flag error handling', () {
    test('--log-level without value prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--log-level'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--log-level'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('--cache-dir without value prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--cache-dir'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--cache-dir'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('--max-cache-size without value prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--max-cache-size'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--max-cache-size'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('--max-concurrent-requests without value prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/dart_pubdev_mcp.dart', '--max-concurrent-requests'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--max-concurrent-requests'));
      expect(result.stderr.toString(), contains('--help'));
    });
  });
}
