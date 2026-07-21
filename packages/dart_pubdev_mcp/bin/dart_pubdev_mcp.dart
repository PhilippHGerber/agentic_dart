/// Entry point for the dart_pubdev_mcp stdio MCP server.
///
/// Reads configuration from CLI flags and environment variables via
/// [PubMcpConfig], constructs a [PubDevClient] and a search [ResponseCache],
/// then starts [PubMcpServer] over stdin/stdout using the dart_mcp stdio
/// transport.
library;

import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:dart_pubdev_mcp/src/cache/cache_registry.dart';
import 'package:dart_pubdev_mcp/src/cache/memory_cache.dart';
import 'package:dart_pubdev_mcp/src/cache/tarball_disk_cache.dart';
import 'package:dart_pubdev_mcp/src/config/config.dart';
import 'package:dart_pubdev_mcp/src/data/pub_client.dart';
import 'package:dart_pubdev_mcp/src/data/sdk_client.dart';
import 'package:dart_pubdev_mcp/src/identity.dart';
import 'package:dart_pubdev_mcp/src/server.dart';
import 'package:dart_pubdev_mcp/src/trace/wire_trace.dart';
import 'package:dart_pubdev_mcp/src/update/update_check_state_store.dart';
import 'package:dart_pubdev_mcp/src/update/version_compare.dart';
import 'package:dart_pubdev_mcp/src/version.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('$kMcpServerIdentity $packageVersion');
    await _printUpdateBannerIfAvailable(args);
    return;
  }

  if (args.contains('--help')) {
    stdout
      ..writeln(
        'Usage: $kMcpServerIdentity [--log-level <level>] [--cache-dir <path>] '
        '[--max-cache-size <bytes|size>] [--max-concurrent-requests <count>] '
        '[--wire-trace] [--wire-trace-dir <path>] '
        '[--wire-trace-max-preview <bytes>] [--no-update-check]',
      )
      ..writeln('       $kMcpServerIdentity --version')
      ..writeln()
      ..writeln('Options:')
      ..writeln('  --log-level <level>  Minimum log severity (debug|info|warning|error).')
      ..writeln('                       Env: dart_pubdev_mcp_LOG_LEVEL  [default: warning]')
      ..writeln('  --cache-dir <path>   Directory for the on-disk cache.')
      ..writeln(
        '                       Env: dart_pubdev_mcp_CACHE_DIR '
        '[default: XDG_CACHE_HOME/dart_pubdev_mcp or ~/.cache/dart_pubdev_mcp]',
      )
      ..writeln(
        '  --max-cache-size     Total tarball disk cache cap (bytes, KB/MB/GB, KiB/MiB/GiB).',
      )
      ..writeln(
        '                       Env: dart_pubdev_mcp_MAX_CACHE_SIZE '
        '[default: 500 MiB]',
      )
      ..writeln(
        '  --max-concurrent-requests <count>',
      )
      ..writeln(
        '                       Cap on simultaneous in-flight pub.dev requests '
        '(1-64).',
      )
      ..writeln(
        '                       Env: dart_pubdev_mcp_MAX_CONCURRENT_REQUESTS '
        '[default: 5]',
      )
      ..writeln(
        '  --wire-trace         Enable the human-readable Wire Trace diagnostic log.',
      )
      ..writeln(
        '                       Env: dart_pubdev_mcp_WIRE_TRACE  [default: off]',
      )
      ..writeln('  --wire-trace-dir <path>')
      ..writeln('                       Directory for per-session Wire Trace files.')
      ..writeln(
        '                       Env: dart_pubdev_mcp_WIRE_TRACE_DIR '
        '[default: <cache-dir>/wire-trace]',
      )
      ..writeln('  --wire-trace-max-preview <bytes>')
      ..writeln(
        '                       Cap on each logged body preview (0 = metadata-only).',
      )
      ..writeln(
        '                       Env: dart_pubdev_mcp_WIRE_TRACE_MAX_PREVIEW '
        '[default: 2048]',
      )
      ..writeln(
        '  --no-update-check    Disable the startup Update Check against pub.dev.',
      )
      ..writeln(
        '                       Env: dart_pubdev_mcp_UPDATE_CHECK  [default: on]',
      )
      ..writeln('  --version            Print version and exit.')
      ..writeln('  --help               Print this help and exit.');
    return;
  }

  final PubMcpConfig config;
  try {
    config = PubMcpConfig.fromArguments(args);
  } on FormatException catch (e) {
    stderr
      ..writeln('Error: ${e.message}')
      ..writeln('Run `$kMcpServerIdentity --help` for usage.');
    exit(64); // EX_USAGE
  }
  final tarballCache = TarballDiskCache(
    directoryPath: config.cacheDir,
    maxSizeBytes: config.maxCacheSizeBytes,
  );

  // Construct the Wire Trace only when the operator opted in; when disabled we
  // install nothing and the server/client/caches pay nothing for the feature.
  // It is built before the client and caches so its logger can be injected into
  // both pub.dev boundaries.
  final trace = config.wireTrace
      ? WireTrace.open(
          directoryPath: config.wireTraceDir,
          serverVersion: packageVersion,
          maxPreviewBytes: config.wireTraceMaxPreview,
          concurrency: config.maxConcurrentRequests,
          cacheDir: config.cacheDir,
        )
      : null;

  final packageInfoCache = ResponseCache<Map<String, Object?>>(trace: trace);

  final client = PubDevClient(
    tarballCache: tarballCache,
    packageInfoCache: packageInfoCache,
    maxConcurrency: config.maxConcurrentRequests,
    trace: trace,
  );

  // Shares tarballCache with `client` so SDK and pub.dev tarballs live in one
  // on-disk cache directory (ADR 0006).
  final sdkClient = SdkClient(tarballCache: tarballCache);

  final cacheRegistry = CacheRegistry(client: client, sdkClient: sdkClient, trace: trace);

  final server = PubMcpServer(
    stdioChannel(input: stdin, output: stdout),
    config: config,
    client: client,
    cacheRegistry: cacheRegistry,
    trace: trace,
  );

  await server.done;
  client.close();
  sdkClient.close();
  trace?.close();
}

/// Prints the Update Banner's second line (see `CONTEXT.md`) when this
/// server's already-persisted Update Check state shows a newer Latest Stable
/// Version than [packageVersion]. Never makes a pub.dev call — only reads
/// whatever `UpdateCheckStateStore` already has on disk. Any failure while
/// resolving the cache directory, reading the state file, or parsing it
/// falls back to printing nothing, silently, so `--version` can never fail
/// or change exit code because of this.
Future<void> _printUpdateBannerIfAvailable(List<String> args) async {
  try {
    final resolved = PubMcpConfig.resolveUpdateBannerInputs(args);
    if (!resolved.updateCheck) return;

    final state = await UpdateCheckStateStore(directoryPath: resolved.cacheDir).read();
    if (state == null) return;
    if (!isNewerVersion(state.latestVersion, packageVersion)) return;

    stdout.writeln(
      'Update available: ${state.latestVersion} — run '
      '`dart install dart_pubdev_mcp --overwrite` to upgrade.',
    );
  } on Object {
    // Best-effort: never turn `--version` into a command that can fail.
  }
}
