/// Unit tests for [PubMcpConfig] and [LogLevel].
library;

import 'dart:io';

import 'package:pubdev_context/src/config/config.dart';
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
      expect(config.cacheDir, endsWith('pubdev_context'));
    });

    test('maxCacheSizeBytes defaults to 500 MiB', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.maxCacheSizeBytes, equals(kDefaultMaxCacheSizeBytes));
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
  });

  group('PubMcpConfig environment variables', () {
    test('pubdev_context_LOG_LEVEL=info sets logLevel to info when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'pubdev_context_LOG_LEVEL': 'info'},
      );
      expect(config.logLevel, equals(LogLevel.info));
    });

    test('pubdev_context_CACHE_DIR sets cacheDir when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'pubdev_context_CACHE_DIR': '/env/cache'},
      );
      expect(config.cacheDir, equals('/env/cache'));
    });

    test('pubdev_context_MAX_CACHE_SIZE sets maxCacheSizeBytes when no flag is present', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'pubdev_context_MAX_CACHE_SIZE': '42MiB'},
      );
      expect(config.maxCacheSizeBytes, equals(42 * 1024 * 1024));
    });

    test('uses XDG_CACHE_HOME when cache dir is not explicitly set', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'XDG_CACHE_HOME': '/xdg/cache'},
      );
      expect(config.cacheDir, equals('/xdg/cache/pubdev_context'));
    });

    test('falls back to HOME/.cache/pubdev_context when XDG_CACHE_HOME is unset', () {
      final config = PubMcpConfig.fromArguments(
        [],
        environment: {'HOME': '/home/tester'},
      );
      expect(config.cacheDir, equals('/home/tester/.cache/pubdev_context'));
    });
  });

  group('PubMcpConfig precedence', () {
    test('--log-level flag overrides pubdev_context_LOG_LEVEL env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--log-level', 'debug'],
        environment: {'pubdev_context_LOG_LEVEL': 'info'},
      );
      expect(config.logLevel, equals(LogLevel.debug));
    });

    test('--cache-dir flag overrides pubdev_context_CACHE_DIR env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--cache-dir', '/flag/cache'],
        environment: {'pubdev_context_CACHE_DIR': '/env/cache'},
      );
      expect(config.cacheDir, equals('/flag/cache'));
    });

    test('--max-cache-size flag overrides pubdev_context_MAX_CACHE_SIZE env var', () {
      final config = PubMcpConfig.fromArguments(
        ['--max-cache-size', '10MiB'],
        environment: {'pubdev_context_MAX_CACHE_SIZE': '1MiB'},
      );
      expect(config.maxCacheSizeBytes, equals(10 * 1024 * 1024));
    });
  });

  group('PubMcpConfig const constructor', () {
    test('const constructor has logLevel warning by default', () {
      const config = PubMcpConfig();
      expect(config.logLevel, equals(LogLevel.warning));
    });

    test('const constructor has default cacheDir', () {
      const config = PubMcpConfig();
      expect(config.cacheDir, equals('.cache/pubdev_context'));
    });

    test('const constructor has default maxCacheSizeBytes', () {
      const config = PubMcpConfig();
      expect(config.maxCacheSizeBytes, equals(kDefaultMaxCacheSizeBytes));
    });

    test('const constructor accepts explicit values', () {
      const config = PubMcpConfig(
        logLevel: LogLevel.debug,
        cacheDir: '/cache',
        maxCacheSizeBytes: 123,
      );
      expect(config.logLevel, equals(LogLevel.debug));
      expect(config.cacheDir, equals('/cache'));
      expect(config.maxCacheSizeBytes, equals(123));
    });
  });

  group('binary --version and --help', () {
    test('--version prints pubdev_context and the current version, then exits 0', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/pubdev_context.dart', '--version'],
      );
      expect(result.exitCode, equals(0));
      expect(result.stdout, contains('pubdev_context '));
    });

    test('--help prints usage summary and exits 0', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/pubdev_context.dart', '--help'],
      );
      expect(result.exitCode, equals(0));
      expect(result.stdout.toString(), contains('Usage:'));
      expect(result.stdout.toString(), contains('--max-cache-size'));
    });
  });

  group('binary bad-flag error handling', () {
    test('invalid --max-cache-size prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/pubdev_context.dart', '--max-cache-size=foo'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('Invalid cache size'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('invalid --log-level prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/pubdev_context.dart', '--log-level=verbose'],
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
        ['run', 'bin/pubdev_context.dart', '--log-level'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--log-level'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('--cache-dir without value prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/pubdev_context.dart', '--cache-dir'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--cache-dir'));
      expect(result.stderr.toString(), contains('--help'));
    });

    test('--max-cache-size without value prints readable error and exits 64', () async {
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/pubdev_context.dart', '--max-cache-size'],
      );
      expect(result.exitCode, equals(64));
      expect(result.stderr.toString(), contains('--max-cache-size'));
      expect(result.stderr.toString(), contains('--help'));
    });
  });
}
