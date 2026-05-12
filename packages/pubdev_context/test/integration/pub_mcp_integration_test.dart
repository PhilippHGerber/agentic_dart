/// Integration tests for pubdev_context against the live pub.dev API.
///
/// NOT run by default — requires a live network connection.
/// Run with: dart test test/integration/
///
/// Test subjects use stable, well-known packages: http, path, signals,
/// dart_mcp. These are safe to query without risk of false failures.
///
/// See issue #13 for the full implementation.
library;

import 'package:test/test.dart';

void main() {
  group('pubdev_context integration', () {
    test('placeholder — replace with live API tests in issue #13', () {
      // This file is excluded from `dart test` by dart_test.yaml.
      // Run explicitly: dart test test/integration/
    });
  });
}
