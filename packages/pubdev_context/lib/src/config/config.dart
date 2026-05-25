/// Typed configuration for pubdev_context.
library;

import 'dart:io';

import 'package:cli_config/cli_config.dart';

/// Default total size cap for the tarball disk cache: 500 MiB.
const int kDefaultMaxCacheSizeBytes = 500 * 1024 * 1024;

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
/// `pubdev_context_CACHE_DIR`. [maxCacheSizeBytes] is read from
/// `--max-cache-size` or `pubdev_context_MAX_CACHE_SIZE`. CLI flags take strict
/// precedence over environment variables; environment variables take precedence
/// over built-in defaults.
/// No config file support in v0.x.
final class PubMcpConfig {
  /// Creates a [PubMcpConfig] with the provided [logLevel] and [cacheDir].
  ///
  /// [logLevel] defaults to [LogLevel.warning] when omitted.
  /// [cacheDir] defaults to `.cache/pubdev_context` — a relative path that
  /// resolves against the process working directory. This constructor is
  /// intended for tests and compile-time constants; production code should use
  /// [PubMcpConfig.fromArguments], which resolves the platform cache directory
  /// via `XDG_CACHE_HOME`, `HOME`, or the system temp directory.
  const PubMcpConfig({
    this.logLevel = LogLevel.warning,
    this.cacheDir = '.cache/pubdev_context',
    this.maxCacheSizeBytes = kDefaultMaxCacheSizeBytes,
  });

  /// Constructs a [PubMcpConfig] from [args] and an optional [environment] map.
  ///
  /// Parses `--log-level <level>`, `--cache-dir <path>`, and
  /// `--max-cache-size <bytes|size>` (as well as their `=`-separated forms)
  /// from [args]. When [environment] is omitted, [Platform.environment] is
  /// used. CLI flags take precedence over the corresponding environment vars.
  factory PubMcpConfig.fromArguments(
    List<String> args, {
    Map<String, String>? environment,
  }) {
    String? logLevelArg;
    String? cacheDirArg;
    String? maxCacheSizeArg;

    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--log-level') {
        if (i + 1 >= args.length) {
          throw const FormatException(
            '--log-level requires a value (debug|info|warning|error).',
          );
        }
        logLevelArg = args[i + 1];
      } else if (args[i].startsWith('--log-level=')) {
        logLevelArg = args[i].substring('--log-level='.length);
      } else if (args[i] == '--cache-dir') {
        if (i + 1 >= args.length) {
          throw const FormatException('--cache-dir requires a path value.');
        }
        cacheDirArg = args[i + 1];
      } else if (args[i].startsWith('--cache-dir=')) {
        cacheDirArg = args[i].substring('--cache-dir='.length);
      } else if (args[i] == '--max-cache-size') {
        if (i + 1 >= args.length) {
          throw const FormatException(
            '--max-cache-size requires a value (bytes, KB/MB/GB, KiB/MiB/GiB).',
          );
        }
        maxCacheSizeArg = args[i + 1];
      } else if (args[i].startsWith('--max-cache-size=')) {
        maxCacheSizeArg = args[i].substring('--max-cache-size='.length);
      }
    }

    final env = environment ?? Platform.environment;
    final config = Config(
      commandLineDefines: [
        if (logLevelArg != null) 'log_level=$logLevelArg',
        if (cacheDirArg != null) 'cache_dir=$cacheDirArg',
        if (maxCacheSizeArg != null) 'max_cache_size=$maxCacheSizeArg',
      ],
      environment: _remapEnvironment(env),
    );

    final logLevelStr = config.optionalString('log_level') ?? 'warning';
    final cacheDir = config.optionalString('cache_dir') ?? _defaultCacheDir(env);
    final maxCacheSizeRaw = config.optionalString('max_cache_size') ?? '$kDefaultMaxCacheSizeBytes';
    final maxCacheSizeBytes = _parseByteSize(maxCacheSizeRaw);

    return PubMcpConfig(
      logLevel: LogLevel.parse(logLevelStr),
      cacheDir: cacheDir,
      maxCacheSizeBytes: maxCacheSizeBytes,
    );
  }

  /// The minimum severity level for log output.
  final LogLevel logLevel;

  /// The directory used for the on-disk tarball cache.
  final String cacheDir;

  /// Maximum allowed combined size for tarballs in [cacheDir], in bytes.
  final int maxCacheSizeBytes;

  static Map<String, String> _remapEnvironment(Map<String, String> env) => {
    'LOG_LEVEL': ?env['pubdev_context_LOG_LEVEL'],
    'CACHE_DIR': ?env['pubdev_context_CACHE_DIR'],
    'MAX_CACHE_SIZE': ?env['pubdev_context_MAX_CACHE_SIZE'],
  };

  static String _defaultCacheDir(Map<String, String> env) {
    final xdg = env['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return _joinPath(xdg, 'pubdev_context');
    }

    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return _joinPath(_joinPath(home, '.cache'), 'pubdev_context');
    }

    // Last resort: system temp directory. Guaranteed to be writable and
    // absolute even on headless or sandboxed hosts where neither
    // XDG_CACHE_HOME nor HOME is available (e.g. minimal Docker images,
    // some MCP sandbox environments). Note that temp directories are typically
    // cleaned on system restart, so cached tarballs will not survive a reboot.
    return _joinPath(Directory.systemTemp.path, 'pubdev_context');
  }

  static int _parseByteSize(String raw) {
    final trimmed = raw.trim().toLowerCase();
    final match = RegExp(r'^(\d+)\s*([kmg]i?b)?$').firstMatch(trimmed);
    if (match == null) {
      throw FormatException(
        'Invalid cache size: "$raw". Use bytes or suffixes KB/MB/GB/KiB/MiB/GiB.',
      );
    }

    final rawDigits = match.group(1);
    if (rawDigits == null) {
      // The regex requires a leading digit group, so this branch is unreachable
      // in practice. The explicit check preserves static null safety without
      // relying on a runtime null-assertion.
      throw const FormatException('Unexpected regex state: digit group is null.');
    }
    final value = int.parse(rawDigits);
    final unit = match.group(2);

    final multiplier = switch (unit) {
      null => 1,
      'kb' => 1000,
      'mb' => 1000 * 1000,
      'gb' => 1000 * 1000 * 1000,
      'kib' => 1024,
      'mib' => 1024 * 1024,
      'gib' => 1024 * 1024 * 1024,
      _ => throw FormatException('Invalid cache size unit: "$unit".'),
    };

    final bytes = value * multiplier;
    if (bytes <= 0) {
      throw const FormatException('Cache size must be greater than zero.');
    }
    return bytes;
  }

  static String _joinPath(String base, String child) {
    final separator = Platform.pathSeparator;
    if (base.endsWith(separator)) return '$base$child';
    return '$base$separator$child';
  }
}
