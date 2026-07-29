/// Guard against SDK package names reaching a pub.dev-package tool handler.
///
/// `flutter`, `flutter_test`, and their siblings are never published on
/// pub.dev — they ship inside the `flutter/flutter` repository's `packages/`
/// directory instead. Calling any pub.dev-package tool (`get_package`,
/// `grep_package_source`, …) with one of these names today surfaces a
/// confusing generic `PACKAGE_NOT_FOUND` (or, worse, an `UNEXPECTED_RESPONSE`
/// tarball-decode failure) with no hint that the name belongs to the SDK tool
/// family instead. [sdkPackageGuardError] gives every such tool a single,
/// sharpened error to return instead.
///
/// See `issues/grep-sdk-source-tool/02-sdk-package-name-guard.md`.
library;

import '../data/domain_error.dart';

/// The Flutter SDK's `packages/` directory names — exactly the set
/// `get_sdk_source_slice`'s `sdk: 'flutter'` mode resolves against
/// (`packages/$package/lib/$file`). Scoped to precisely what the SDK tools
/// can serve; not a broader heuristic.
const sdkPackageNames = <String>{
  'flutter',
  'flutter_test',
  'flutter_driver',
  'flutter_localizations',
  'flutter_web_plugins',
  'integration_test',
};

/// Returns a sharpened [DomainErrors.packageNotFound] error when [package] is
/// one of [sdkPackageNames], or `null` when it is not (the ordinary case).
///
/// Callers check this before touching `VersionResolver` or a pub.dev client
/// at all, so an explicit `version` argument cannot bypass the guard — the
/// name genuinely isn't a pub.dev package regardless of which version was
/// requested.
DomainError? sdkPackageGuardError(String package) {
  if (!sdkPackageNames.contains(package)) return null;
  return DomainError(
    code: DomainErrors.packageNotFound,
    message: '"$package" is not a package published on pub.dev.',
    suggestion:
        '"$package" is part of the Flutter SDK (the flutter/flutter repository\'s '
        'packages/ directory), not a pub.dev package — pub.dev-package tools like this '
        'one cannot serve it.',
    suggestedNextStep: {
      'tool': 'grep_sdk_source',
      'arguments': {'sdk': 'flutter', 'package': package},
    },
  );
}
