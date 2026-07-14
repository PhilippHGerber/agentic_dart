/// Performance benchmarks for dart_pubdev_mcp tools.
///
/// Measures p50 and p95 latency for all five tools against the live
/// pub.dev API under cold-cache and warm-cache conditions.
///
/// Not part of the test suite — invoke explicitly:
///   dart run benchmark/dart_pubdev_mcp_bench.dart
///
/// See `issues/pub-dev-mcp/13-integration-tests.md`.
library;

import 'dart:io';

void main() {
  // TODO(issues/pub-dev-mcp/13): implement latency benchmarks for all five tools
  stdout.writeln('[dart_pubdev_mcp bench] not yet implemented — see issue 13');
}
