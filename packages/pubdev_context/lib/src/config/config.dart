/// Typed configuration for pubdev_context.
library;

import 'dart:io';

import 'package:cli_config/cli_config.dart';

/// The minimum severity level for log output.
enum LogLevel {
  /// Fine-grained diagnostic output intended for development.
  debug,

  /// General informational messages about server operation.
  info,

  /// Potentially harmful situations that do not halt execution.
  warning,

  /// Error conditions that may still allow the server to continue running.
  error;

  /// Parses [value] (case-insensitive) as a [LogLevel].
  ///
  /// Throws [FormatException] when [value] does not match a known level name.
  static LogLevel parse(String value) => switch (value.toLowerCase()) {
    'debug' => debug,
    'info' => info,
    'warning' => warning,
    'error' => error,
    _ => throw FormatException('Unknown log level: "$value"'),
  };
}

/// Typed configuration for the pubdev_context server.
///
/// Reads [logLevel] from the `--log-level` flag or the `pubdev_context_LOG_LEVEL`
/// environment variable, and [cacheDir] from `--cache-dir` or
/// `pubdev_context_CACHE_DIR`. CLI flags take strict precedence over environment
/// variables; environment variables take precedence over built-in defaults.
/// No config file support in v0.x.
final class PubMcpConfig {
  /// Creates a [PubMcpConfig] with the provided [logLevel] and [cacheDir].
  ///
  /// [logLevel] defaults to [LogLevel.warning] when omitted.
  /// [cacheDir] defaults to `null`, which disables the on-disk cache.
  const PubMcpConfig({
    this.logLevel = LogLevel.warning,
    this.cacheDir,
  });

  /// Constructs a [PubMcpConfig] from [args] and an optional [environment] map.
  ///
  /// Parses `--log-level <level>` and `--cache-dir <path>` (as well as their
  /// `=`-separated forms) from [args]. When [environment] is omitted,
  /// [Platform.environment] is used. CLI flags take precedence over
  /// `pubdev_context_LOG_LEVEL` and `pubdev_context_CACHE_DIR` env vars.
  factory PubMcpConfig.fromArguments(
    List<String> args, {
    Map<String, String>? environment,
  }) {
    String? logLevelArg;
    String? cacheDirArg;

    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--log-level' && i + 1 < args.length) {
        logLevelArg = args[i + 1];
      } else if (args[i].startsWith('--log-level=')) {
        logLevelArg = args[i].substring('--log-level='.length);
      } else if (args[i] == '--cache-dir' && i + 1 < args.length) {
        cacheDirArg = args[i + 1];
      } else if (args[i].startsWith('--cache-dir=')) {
        cacheDirArg = args[i].substring('--cache-dir='.length);
      }
    }

    final env = environment ?? Platform.environment;
    final config = Config(
      commandLineDefines: [
        if (logLevelArg != null) 'log_level=$logLevelArg',
        if (cacheDirArg != null) 'cache_dir=$cacheDirArg',
      ],
      environment: _remapEnvironment(env),
    );

    final logLevelStr = config.optionalString('log_level') ?? 'warning';
    final cacheDir = config.optionalString('cache_dir');

    return PubMcpConfig(
      logLevel: LogLevel.parse(logLevelStr),
      cacheDir: cacheDir,
    );
  }

  /// The minimum severity level for log output.
  final LogLevel logLevel;

  /// The directory used for the on-disk cache, or `null` to disable caching.
  final String? cacheDir;

  static Map<String, String> _remapEnvironment(Map<String, String> env) => {
    'LOG_LEVEL': ?env['pubdev_context_LOG_LEVEL'],
    'CACHE_DIR': ?env['pubdev_context_CACHE_DIR'],
  };
}
