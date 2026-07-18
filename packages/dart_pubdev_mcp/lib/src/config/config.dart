/// Typed configuration for dart_pubdev_mcp.
library;

import 'dart:io';

import 'package:cli_config/cli_config.dart';

/// Default total size cap for the tarball disk cache: 500 MiB.
const int kDefaultMaxCacheSizeBytes = 500 * 1024 * 1024;

/// Default cap on the number of in-flight pub.dev HTTP requests.
const int kDefaultMaxConcurrentRequests = 5;

/// Upper bound accepted for `--max-concurrent-requests`.
///
/// A concurrency cap is a protection mechanism, not a throughput dial: values
/// far above this exhaust file descriptors locally and burst against pub.dev in
/// a way that invites rate-limiting or a temporary ban. Anything above this is
/// almost certainly a misconfiguration, so it is rejected rather than honoured.
const int kMaxConcurrentRequestsLimit = 64;

/// Default cap, in bytes, on the body preview written to the Wire Trace.
const int kDefaultWireTraceMaxPreview = 2048;

/// The relative cache directory used when no cache dir is configured.
///
/// A single source for the default so the [PubMcpConfig] const constructor and
/// the derived [PubMcpConfig.wireTraceDir] default cannot drift apart.
const String _kDefaultRelativeCacheDir = '.cache/dart_pubdev_mcp';

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

/// Typed configuration for the dart_pubdev_mcp server.
///
/// Reads [logLevel] from the `--log-level` flag or the `dart_pubdev_mcp_LOG_LEVEL`
/// environment variable, and [cacheDir] from `--cache-dir` or
/// `dart_pubdev_mcp_CACHE_DIR`. [maxCacheSizeBytes] is read from
/// `--max-cache-size` or `dart_pubdev_mcp_MAX_CACHE_SIZE`.
/// [maxConcurrentRequests] is read from `--max-concurrent-requests` or
/// `dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS`. [updateCheck] is read from
/// `--no-update-check` or `dart_pubdev_mcp_UPDATE_CHECK`. CLI flags take strict
/// precedence over environment variables; environment variables take precedence
/// over built-in defaults.
/// No config file support in v0.x.
final class PubMcpConfig {
  /// Creates a [PubMcpConfig] with the provided [logLevel] and [cacheDir].
  ///
  /// [logLevel] defaults to [LogLevel.warning] when omitted.
  /// [cacheDir] defaults to `.cache/dart_pubdev_mcp` — a relative path that
  /// resolves against the process working directory. This constructor is
  /// intended for tests and compile-time constants; production code should use
  /// [PubMcpConfig.fromArguments], which resolves the platform cache directory
  /// via `XDG_CACHE_HOME`, `HOME`, or the system temp directory.
  const PubMcpConfig({
    this.logLevel = LogLevel.warning,
    this.cacheDir = _kDefaultRelativeCacheDir,
    this.maxCacheSizeBytes = kDefaultMaxCacheSizeBytes,
    this.maxConcurrentRequests = kDefaultMaxConcurrentRequests,
    this.wireTrace = false,
    this.wireTraceDir = '$_kDefaultRelativeCacheDir/wire-trace',
    this.wireTraceMaxPreview = kDefaultWireTraceMaxPreview,
    this.updateCheck = true,
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
    String? maxConcurrentRequestsArg;
    String? wireTraceArg;
    String? wireTraceDirArg;
    String? wireTraceMaxPreviewArg;
    String? noUpdateCheckArg;

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
      } else if (args[i] == '--max-concurrent-requests') {
        if (i + 1 >= args.length) {
          throw const FormatException(
            '--max-concurrent-requests requires a positive integer value '
            '(1–$kMaxConcurrentRequestsLimit).',
          );
        }
        maxConcurrentRequestsArg = args[i + 1];
      } else if (args[i].startsWith('--max-concurrent-requests=')) {
        maxConcurrentRequestsArg = args[i].substring(
          '--max-concurrent-requests='.length,
        );
      } else if (args[i] == '--wire-trace') {
        // A bare presence flag: `--wire-trace` enables tracing.
        wireTraceArg = 'true';
      } else if (args[i].startsWith('--wire-trace=')) {
        wireTraceArg = args[i].substring('--wire-trace='.length);
      } else if (args[i] == '--wire-trace-dir') {
        if (i + 1 >= args.length) {
          throw const FormatException('--wire-trace-dir requires a path value.');
        }
        wireTraceDirArg = args[i + 1];
      } else if (args[i].startsWith('--wire-trace-dir=')) {
        wireTraceDirArg = args[i].substring('--wire-trace-dir='.length);
      } else if (args[i] == '--wire-trace-max-preview') {
        if (i + 1 >= args.length) {
          throw const FormatException(
            '--wire-trace-max-preview requires a non-negative integer value.',
          );
        }
        wireTraceMaxPreviewArg = args[i + 1];
      } else if (args[i].startsWith('--wire-trace-max-preview=')) {
        wireTraceMaxPreviewArg = args[i].substring(
          '--wire-trace-max-preview='.length,
        );
      } else if (args[i] == '--no-update-check') {
        // A bare presence flag: `--no-update-check` disables the check.
        noUpdateCheckArg = 'true';
      } else if (args[i].startsWith('--no-update-check=')) {
        noUpdateCheckArg = args[i].substring('--no-update-check='.length);
      }
    }

    final env = environment ?? Platform.environment;
    final config = Config(
      commandLineDefines: [
        if (logLevelArg != null) 'log_level=$logLevelArg',
        if (cacheDirArg != null) 'cache_dir=$cacheDirArg',
        if (maxCacheSizeArg != null) 'max_cache_size=$maxCacheSizeArg',
        if (maxConcurrentRequestsArg != null) 'max_concurrent_requests=$maxConcurrentRequestsArg',
        if (wireTraceArg != null) 'wire_trace=$wireTraceArg',
        if (wireTraceDirArg != null) 'wire_trace_dir=$wireTraceDirArg',
        if (wireTraceMaxPreviewArg != null) 'wire_trace_max_preview=$wireTraceMaxPreviewArg',
        if (noUpdateCheckArg != null) 'no_update_check=$noUpdateCheckArg',
      ],
      environment: _remapEnvironment(env),
    );

    final logLevelStr = config.optionalString('log_level') ?? 'warning';
    final cacheDir = config.optionalString('cache_dir') ?? _defaultCacheDir(env);
    final maxCacheSizeRaw = config.optionalString('max_cache_size') ?? '$kDefaultMaxCacheSizeBytes';
    final maxCacheSizeBytes = _parseByteSize(maxCacheSizeRaw);
    final maxConcurrentRaw =
        config.optionalString('max_concurrent_requests') ?? '$kDefaultMaxConcurrentRequests';
    final maxConcurrentRequests = _parseMaxConcurrentRequests(maxConcurrentRaw);
    final wireTrace = config.optionalBool('wire_trace') ?? false;
    final wireTraceDir =
        config.optionalString('wire_trace_dir') ?? _joinPath(cacheDir, 'wire-trace');
    final wireTraceMaxPreviewRaw =
        config.optionalString('wire_trace_max_preview') ?? '$kDefaultWireTraceMaxPreview';
    final wireTraceMaxPreview = _parseWireTraceMaxPreview(wireTraceMaxPreviewRaw);
    // Two keys, not one: the CLI flag (`no_update_check`) and the env var
    // (`update_check`) are opposite polarity by design (see CONTEXT.md's
    // Update Check entry), so they can't share a single `Config` key the way
    // every other boolean option here does. Inverting the resolved bool below
    // avoids re-parsing `no_update_check`'s raw string ourselves, which would
    // otherwise duplicate cli_config's `boolStrings` synonym table.
    final noUpdateCheck = config.optionalBool('no_update_check');
    final updateCheckEnv = config.optionalBool('update_check');
    final updateCheck = noUpdateCheck != null ? !noUpdateCheck : (updateCheckEnv ?? true);

    return PubMcpConfig(
      logLevel: LogLevel.parse(logLevelStr),
      cacheDir: cacheDir,
      maxCacheSizeBytes: maxCacheSizeBytes,
      maxConcurrentRequests: maxConcurrentRequests,
      wireTrace: wireTrace,
      wireTraceDir: wireTraceDir,
      wireTraceMaxPreview: wireTraceMaxPreview,
      updateCheck: updateCheck,
    );
  }

  /// Best-effort resolution of just the cache directory and Update Check
  /// opt-out from [args] and [environment] — the two config values the
  /// Update Banner needs (see `CONTEXT.md`'s **Update Banner** glossary
  /// entry) from the `--version` exit path, which exits before the full
  /// [PubMcpConfig.fromArguments] parse runs.
  ///
  /// Every other flag in [args] is ignored, so a malformed unrelated flag
  /// never affects this resolution. Unlike [PubMcpConfig.fromArguments],
  /// this can throw [FormatException] on a malformed value for either of the
  /// two keys it does read (e.g. an unparseable `--no-update-check=<value>`)
  /// — callers on the "never fail loudly" `--version` path are expected to
  /// catch and fall back rather than this method silently guessing.
  static ({String cacheDir, bool updateCheck}) resolveUpdateBannerInputs(
    List<String> args, {
    Map<String, String>? environment,
  }) {
    String? cacheDirArg;
    String? noUpdateCheckArg;
    for (var i = 0; i < args.length; i++) {
      if (args[i] == '--cache-dir') {
        if (i + 1 < args.length) cacheDirArg = args[i + 1];
      } else if (args[i].startsWith('--cache-dir=')) {
        cacheDirArg = args[i].substring('--cache-dir='.length);
      } else if (args[i] == '--no-update-check') {
        noUpdateCheckArg = 'true';
      } else if (args[i].startsWith('--no-update-check=')) {
        noUpdateCheckArg = args[i].substring('--no-update-check='.length);
      }
    }

    final env = environment ?? Platform.environment;
    final config = Config(
      commandLineDefines: [
        if (cacheDirArg != null) 'cache_dir=$cacheDirArg',
        if (noUpdateCheckArg != null) 'no_update_check=$noUpdateCheckArg',
      ],
      environment: _remapEnvironment(env),
    );

    final cacheDir = config.optionalString('cache_dir') ?? _defaultCacheDir(env);
    final noUpdateCheck = config.optionalBool('no_update_check');
    final updateCheckEnv = config.optionalBool('update_check');
    final updateCheck = noUpdateCheck != null ? !noUpdateCheck : (updateCheckEnv ?? true);

    return (cacheDir: cacheDir, updateCheck: updateCheck);
  }

  /// The minimum severity level for log output.
  final LogLevel logLevel;

  /// The directory used for the on-disk tarball cache.
  final String cacheDir;

  /// Maximum allowed combined size for tarballs in [cacheDir], in bytes.
  final int maxCacheSizeBytes;

  /// Maximum number of pub.dev HTTP requests allowed in flight simultaneously.
  final int maxConcurrentRequests;

  /// Whether the Wire Trace diagnostic log is enabled. Off by default.
  final bool wireTrace;

  /// Directory the Wire Trace writes its per-session files into.
  ///
  /// Defaults to a `wire-trace/` subdirectory of [cacheDir].
  final String wireTraceDir;

  /// Cap, in bytes, on each body preview written to the Wire Trace. A value of
  /// `0` produces a metadata-only trace with no bodies.
  final int wireTraceMaxPreview;

  /// Whether the Update Check runs at server startup. On by default.
  final bool updateCheck;

  static Map<String, String> _remapEnvironment(Map<String, String> env) => {
    'LOG_LEVEL': ?env['dart_pubdev_mcp_LOG_LEVEL'],
    'CACHE_DIR': ?env['dart_pubdev_mcp_CACHE_DIR'],
    'MAX_CACHE_SIZE': ?env['dart_pubdev_mcp_MAX_CACHE_SIZE'],
    'MAX_CONCURRENT_REQUESTS': ?env['dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS'],
    'WIRE_TRACE': ?env['dart_pubdev_mcp_WIRE_TRACE'],
    'WIRE_TRACE_DIR': ?env['dart_pubdev_mcp_WIRE_TRACE_DIR'],
    'WIRE_TRACE_MAX_PREVIEW': ?env['dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW'],
    'UPDATE_CHECK': ?env['dart_pubdev_mcp_UPDATE_CHECK'],
  };

  static int _parseWireTraceMaxPreview(String raw) {
    final value = int.tryParse(raw.trim());
    if (value == null || value < 0) {
      throw FormatException(
        'Invalid wire trace max preview: "$raw". '
        'Use a non-negative integer number of bytes (0 for metadata-only).',
      );
    }
    return value;
  }

  static int _parseMaxConcurrentRequests(String raw) {
    final value = int.tryParse(raw.trim());
    if (value == null || value <= 0) {
      throw FormatException(
        'Invalid max concurrent requests: "$raw". '
        'Use a positive integer between 1 and $kMaxConcurrentRequestsLimit.',
      );
    }
    if (value > kMaxConcurrentRequestsLimit) {
      throw FormatException(
        'Max concurrent requests too large: $value. '
        'Use a value between 1 and $kMaxConcurrentRequestsLimit.',
      );
    }
    return value;
  }

  static String _defaultCacheDir(Map<String, String> env) {
    final xdg = env['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty) {
      return _joinPath(xdg, 'dart_pubdev_mcp');
    }

    final home = env['HOME'];
    if (home != null && home.isNotEmpty) {
      return _joinPath(_joinPath(home, '.cache'), 'dart_pubdev_mcp');
    }

    // Last resort: system temp directory. Guaranteed to be writable and
    // absolute even on headless or sandboxed hosts where neither
    // XDG_CACHE_HOME nor HOME is available (e.g. minimal Docker images,
    // some MCP sandbox environments). Note that temp directories are typically
    // cleaned on system restart, so cached tarballs will not survive a reboot.
    return _joinPath(Directory.systemTemp.path, 'dart_pubdev_mcp');
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
