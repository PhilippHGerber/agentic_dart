/// Unit tests for [sdkPackageGuardError].
library;

import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/sdk_package_guard.dart';
import 'package:test/test.dart';

void main() {
  group('guarded names', () {
    for (final name in sdkPackageNames) {
      test('"$name" returns a sharpened PACKAGE_NOT_FOUND error', () {
        switch (sdkPackageGuardError(name)) {
          case null:
            fail('expected a guard error for "$name"');
          case final error:
            expect(error.code, equals(DomainErrors.packageNotFound));
            expect(error.suggestion, contains('Flutter SDK'));
            expect(error.suggestedNextStep?['tool'], equals('grep_sdk_source'));
            expect(
              (error.suggestedNextStep?['arguments'] as Map<String, Object?>?)?['package'],
              equals(name),
            );
        }
      });
    }
  });

  test('the six guarded names match exactly the flutter/flutter packages/ set', () {
    expect(
      sdkPackageNames,
      equals(const {
        'flutter',
        'flutter_test',
        'flutter_driver',
        'flutter_localizations',
        'flutter_web_plugins',
        'integration_test',
      }),
    );
  });

  group('ordinary pub.dev names', () {
    for (final name in ['http', 'flutter_riverpod', 'provider', '']) {
      test('"$name" is not guarded', () {
        expect(sdkPackageGuardError(name), isNull);
      });
    }
  });
}
