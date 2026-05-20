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

    test('cacheDir is null by default', () {
      final config = PubMcpConfig.fromArguments([], environment: {});
      expect(config.cacheDir, isNull);
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
  });

  group('PubMcpConfig const constructor', () {
    test('const constructor has logLevel warning by default', () {
      const config = PubMcpConfig();
      expect(config.logLevel, equals(LogLevel.warning));
    });

    test('const constructor has null cacheDir by default', () {
      const config = PubMcpConfig();
      expect(config.cacheDir, isNull);
    });

    test('const constructor accepts explicit values', () {
      const config = PubMcpConfig(logLevel: LogLevel.debug, cacheDir: '/cache');
      expect(config.logLevel, equals(LogLevel.debug));
      expect(config.cacheDir, equals('/cache'));
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
    });
  });
}
