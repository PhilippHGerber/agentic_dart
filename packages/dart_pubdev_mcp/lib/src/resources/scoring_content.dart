/// Compile-time content for the `pub://meta/scoring` resource.
///
/// Extracted from `meta_resources.dart` so the `meta` `KeyedCache` facade in
/// `CacheRegistry` can serve it without importing the resource handler (which
/// itself depends on `CacheRegistry` for the facade's `Id` type).
library;

/// Plain-text explanation of the pub.dev 160-point scoring system.
///
/// Embedded at compile time. No HTTP call or file I/O is performed on any
/// access to `pub://meta/scoring`; this constant is the sole source of the
/// resource body.
const kScoringContent = '''
pub.dev 160-Point Scoring System
=================================

pub.dev scores every package on a 0-160 scale using the pana analysis tool.
Scores are recomputed automatically on each new version publish.

CATEGORY 1 -- Follow Dart file conventions (0-20 points)
---------------------------------------------------------
Checks that the package follows the conventional structure expected of a
well-maintained Dart package.

Points are awarded for:
  * README.md is present and non-trivial.
  * CHANGELOG.md is present, non-trivial, and follows Keep-a-Changelog format.
  * A working example is provided (example/ directory or inline dartdoc examples).
  * pubspec.yaml contains a description between 60 and 180 characters.
  * pubspec.yaml contains a valid homepage or repository URL.
  * SDK and dependency version constraints are compatible and not overly tight.
  * No deprecated Dart API usage is detected by the analyzer.

CATEGORY 2 -- Provide documentation (0-10 points)
--------------------------------------------------
Checks that public symbols carry doc comments (///).

Points scale with the percentage of public API members that have a doc comment.
Full marks require >= 80% coverage. The package main library must also carry
a library-level doc comment.

CATEGORY 3 -- Platform support (0-20 points)
---------------------------------------------
Rewards packages that run on many platforms and runtimes.

Detected platforms: Android, iOS, macOS, Linux, Windows, Web.
Points increase with the number of supported platforms. Annotate the supported
platforms in pubspec.yaml under the flutter.plugin.platforms section (Flutter
packages) or declare sdk: dart with no platform-exclusive imports (Dart-only).

CATEGORY 4 -- Pass static analysis (0-50 points)
-------------------------------------------------
The most heavily weighted category. Points are deducted for any issue reported
by dart analyze, including:

  * Analyzer errors or warnings.
  * Lints triggered under the recommended or very_good_analysis rule sets.
  * Code that has not been formatted with dart format.
  * Use of dynamic or missing return-type annotations.

Zero errors and zero warnings with formatted code yield the full 50 points.
Even a single analyzer warning can reduce the score significantly.

CATEGORY 5 -- Support up-to-date dependencies (0-60 points)
------------------------------------------------------------
Rewards packages whose dependencies allow the latest published versions.

pana checks each direct dependency listed in pubspec.yaml:
  * All constraints include the latest version     -> full points.
  * One or more constraints exclude latest version -> proportional deduction.
  * Any dependency has been discontinued/retracted -> heavy penalty.

Best practices:
  * Use caret syntax (^x.y.z) to allow compatible upgrades.
  * Avoid pinned exact versions (== x.y.z) -- they lose points as dependencies
    advance.
  * Run dart pub upgrade and republish promptly after dependency releases.

SUMMARY
-------
Category                          Max pts  Key action
Follow Dart file conventions           20  README, CHANGELOG, example, pubspec
Provide documentation                  10  /// on >= 80% of public API members
Platform support                       20  Declare all supported platforms
Pass static analysis                   50  Zero analyzer issues; dart format clean
Support up-to-date dependencies        60  Open upper bounds; update promptly
TOTAL                                 160
''';
