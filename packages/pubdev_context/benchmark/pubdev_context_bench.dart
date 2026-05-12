/// Performance benchmarks for pubdev_context tools.
///
/// Measures p50 and p95 latency for all five tools against the live
/// pub.dev API under cold-cache and warm-cache conditions.
///
/// Not part of the test suite — invoke explicitly:
///   dart run benchmark/pubdev_context_bench.dart
///
/// See `issues/pub-dev-mcp/13-integration-tests.md`.
library;

import 'dart:io';

void main() {
  // TODO(issues/pub-dev-mcp/13): implement latency benchmarks for all five tools
  stdout.writeln('[pubdev_context bench] not yet implemented — see issue 13');
}
