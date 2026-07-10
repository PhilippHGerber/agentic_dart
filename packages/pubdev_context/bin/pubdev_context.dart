/// Entry point for the pubdev_context stdio MCP server.
///
/// Reads configuration from CLI flags and environment variables via
/// [PubMcpConfig], constructs a [PubDevClient] and a search [ResponseCache],
/// then starts [PubMcpServer] over stdin/stdout using the dart_mcp stdio
/// transport.
library;

import 'dart:io';

import 'package:dart_mcp/stdio.dart';
import 'package:pubdev_context/src/cache/memory_cache.dart';
import 'package:pubdev_context/src/cache/tarball_disk_cache.dart';
import 'package:pubdev_context/src/config/config.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/server.dart';
import 'package:pubdev_context/src/trace/wire_trace.dart';
import 'package:pubdev_context/src/version.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('pubdev_context $packageVersion');
    return;
  }

  if (args.contains('--help')) {
    stdout
      ..writeln(
        'Usage: pubdev_context [--log-level <level>] [--cache-dir <path>] '
        '[--max-cache-size <bytes|size>] [--max-concurrent-requests <count>] '
        '[--wire-trace] [--wire-trace-dir <path>] '
        '[--wire-trace-max-preview <bytes>]',
      )
      ..writeln('       pubdev_context --version')
      ..writeln()
      ..writeln('Options:')
      ..writeln('  --log-level <level>  Minimum log severity (debug|info|warning|error).')
      ..writeln('                       Env: pubdev_context_LOG_LEVEL  [default: warning]')
      ..writeln('  --cache-dir <path>   Directory for the on-disk cache.')
      ..writeln(
        '                       Env: pubdev_context_CACHE_DIR '
        '[default: XDG_CACHE_HOME/pubdev_context or ~/.cache/pubdev_context]',
      )
      ..writeln(
        '  --max-cache-size     Total tarball disk cache cap (bytes, KB/MB/GB, KiB/MiB/GiB).',
      )
      ..writeln(
        '                       Env: pubdev_context_MAX_CACHE_SIZE '
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
        '                       Env: pubdev_context_MAX_CONCURRENT_REQUESTS '
        '[default: 5]',
      )
      ..writeln(
        '  --wire-trace         Enable the human-readable Wire Trace diagnostic log.',
      )
      ..writeln(
        '                       Env: pubdev_context_WIRE_TRACE  [default: off]',
      )
      ..writeln('  --wire-trace-dir <path>')
      ..writeln('                       Directory for per-session Wire Trace files.')
      ..writeln(
        '                       Env: pubdev_context_WIRE_TRACE_DIR '
        '[default: <cache-dir>/wire-trace]',
      )
      ..writeln('  --wire-trace-max-preview <bytes>')
      ..writeln(
        '                       Cap on each logged body preview (0 = metadata-only).',
      )
      ..writeln(
        '                       Env: pubdev_context_WIRE_TRACE_MAX_PREVIEW '
        '[default: 2048]',
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
      ..writeln('Run `pubdev_context --help` for usage.');
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

  final searchCache = ResponseCache<List<PackageSummary>>(trace: trace);
  final packageCache = ResponseCache<PackageDetail>(trace: trace);
  final packageVersionsCache = ResponseCache<List<PackageVersion>>(trace: trace);
  final changelogCache = ResponseCache<List<ChangelogEntry>>(trace: trace);
  final changelogRawCache = ResponseCache<String>(trace: trace);
  final apiIndexCache = ResponseCache<List<DartdocSymbol>>(trace: trace);
  final readmeCache = ResponseCache<String>(trace: trace);
  final symbolDocCache = ResponseCache<String>(trace: trace);
  final sourceFilesCache = ResponseCache<Map<String, String>>(trace: trace);
  final metaCache = ResponseCache<String>(trace: trace);

  final server = PubMcpServer(
    stdioChannel(input: stdin, output: stdout),
    config: config,
    client: client,
    searchCache: searchCache,
    packageCache: packageCache,
    packageVersionsCache: packageVersionsCache,
    changelogCache: changelogCache,
    changelogRawCache: changelogRawCache,
    apiIndexCache: apiIndexCache,
    readmeCache: readmeCache,
    symbolDocCache: symbolDocCache,
    sourceFilesCache: sourceFilesCache,
    metaCache: metaCache,
    trace: trace,
  );

  await server.done;
  client.close();
  trace?.close();
}
