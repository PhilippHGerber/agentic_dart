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
import 'package:pubdev_context/src/config/config.dart';
import 'package:pubdev_context/src/data/models.dart';
import 'package:pubdev_context/src/data/pub_client.dart';
import 'package:pubdev_context/src/server.dart';
import 'package:pubdev_context/src/version.dart';

Future<void> main(List<String> args) async {
  if (args.contains('--version')) {
    stdout.writeln('pubdev_context $packageVersion');
    return;
  }

  if (args.contains('--help')) {
    stdout
      ..writeln('Usage: pubdev_context [--log-level <level>] [--cache-dir <path>]')
      ..writeln('       pubdev_context --version')
      ..writeln()
      ..writeln('Options:')
      ..writeln('  --log-level <level>  Minimum log severity (debug|info|warning|error).')
      ..writeln('                       Env: pubdev_context_LOG_LEVEL  [default: warning]')
      ..writeln('  --cache-dir <path>   Directory for the on-disk cache.')
      ..writeln('                       Env: pubdev_context_CACHE_DIR  [default: disabled]')
      ..writeln('  --version            Print version and exit.')
      ..writeln('  --help               Print this help and exit.');
    return;
  }

  final config = PubMcpConfig.fromArguments(args);
  final client = PubDevClient();
  final searchCache = ResponseCache<List<PackageSummary>>();
  final packageCache = ResponseCache<PackageDetail>();
  final changelogCache = ResponseCache<List<ChangelogEntry>>();
  final apiIndexCache = ResponseCache<List<DartdocSymbol>>();
  final readmeCache = ResponseCache<String>();
  final metaCache = ResponseCache<String>();

  final server = PubMcpServer(
    stdioChannel(input: stdin, output: stdout),
    config: config,
    client: client,
    searchCache: searchCache,
    packageCache: packageCache,
    changelogCache: changelogCache,
    apiIndexCache: apiIndexCache,
    readmeCache: readmeCache,
    metaCache: metaCache,
  );

  await server.done;
  client.close();
}
