/// Unit tests for all pub.dev response models.
library;

import 'dart:convert';
import 'dart:io';

import 'package:pubdev_context/src/data/models.dart';
import 'package:test/test.dart';

Map<String, Object?> _loadFixture(String name) {
  final file = File('test/fixtures/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

List<Object?> _loadFixtureList(String name) {
  final file = File('test/fixtures/$name');
  return jsonDecode(file.readAsStringSync()) as List<Object?>;
}

void main() {
  final packageInfo = _loadFixture('package_info.json');
  final packageScore = _loadFixture('package_score.json');
  final packageMetrics = _loadFixture('package_metrics.json');
  final indexJson = _loadFixtureList('index_json.json');

  // A fixed "now" so daysSinceUpdate calculations are deterministic.
  final fixedNow = DateTime.parse('2026-05-10T00:00:00Z');

  // ─── PackageScore ──────────────────────────────────────────────────────────

  group('PackageScore.fromJson', () {
    test('parses likeCount into likes', () {
      final score = PackageScore.fromJson(packageScore);
      expect(score.likes, equals(8435));
    });

    test('parses grantedPoints into pubPoints', () {
      final score = PackageScore.fromJson(packageScore);
      expect(score.pubPoints, equals(160));
    });

    test('parses downloadCount30Days into popularity', () {
      final score = PackageScore.fromJson(packageScore);
      expect(score.popularity, equals(8519847));
    });

    test('defaults to 0 for missing fields', () {
      final score = PackageScore.fromJson(const {});
      expect(score.likes, isZero);
      expect(score.pubPoints, isZero);
      expect(score.popularity, isZero);
    });

    test('copyWith replaces likes', () {
      final base = PackageScore.fromJson(packageScore);
      expect(base.copyWith(likes: 1).likes, equals(1));
    });

    test('copyWith leaves unchanged fields intact', () {
      final base = PackageScore.fromJson(packageScore);
      expect(base.copyWith(likes: 1).pubPoints, equals(base.pubPoints));
    });
  });

  // ─── SdkConstraints ───────────────────────────────────────────────────────

  group('SdkConstraints.fromJson', () {
    test('parses dart sdk constraint', () {
      final env = {'sdk': '^3.4.0'};
      expect(SdkConstraints.fromJson(env).dart, equals('^3.4.0'));
    });

    test('flutter constraint is null when absent', () {
      expect(SdkConstraints.fromJson({'sdk': '^3.4.0'}).flutter, isNull);
    });

    test('parses flutter sdk constraint when present', () {
      final env = {'sdk': '^3.4.0', 'flutter': '>=3.0.0'};
      expect(SdkConstraints.fromJson(env).flutter, equals('>=3.0.0'));
    });

    test('defaults dart to >=3.0.0 <4.0.0 when sdk key absent', () {
      expect(SdkConstraints.fromJson(const {}).dart, equals('>=3.0.0 <4.0.0'));
    });

    test('copyWith replaces dart constraint', () {
      final base = SdkConstraints.fromJson({'sdk': '^3.4.0'});
      expect(base.copyWith(dart: '^4.0.0').dart, equals('^4.0.0'));
    });
  });

  // ─── PackageSummary ───────────────────────────────────────────────────────

  group('PackageSummary.fromPackageAndScore', () {
    late PackageSummary summary;

    setUp(() {
      summary = PackageSummary.fromPackageAndScore(
        packageInfo,
        packageScore,
        now: fixedNow,
      );
    });

    test('name is parsed from package info', () {
      expect(summary.name, equals('http'));
    });

    test('version is latest.version from package info', () {
      expect(summary.version, equals('1.6.0'));
    });

    test('description is from pubspec', () {
      expect(
        summary.description,
        equals('A composable, multi-platform, Future-based API for HTTP requests.'),
      );
    });

    test('likes come from likeCount in score', () {
      expect(summary.likes, equals(8435));
    });

    test('pubPoints come from grantedPoints in score', () {
      expect(summary.pubPoints, equals(160));
    });

    test('popularity comes from downloadCount30Days in score', () {
      expect(summary.popularity, equals(8519847));
    });

    test('publisher is extracted from publisher: tag', () {
      expect(summary.publisher, equals('dart.dev'));
    });

    test('verified is true when publisher tag is present', () {
      expect(summary.verified, isTrue);
    });

    test('sdks are extracted from sdk: tags', () {
      expect(summary.sdks, containsAll(['dart', 'flutter']));
    });

    test('platforms are extracted from platform: tags', () {
      expect(summary.platforms, containsAll(['android', 'ios', 'web']));
    });

    test('topics come from pubspec topics array', () {
      expect(summary.topics, containsAll(['http', 'network', 'protocols']));
    });

    test('license is first license: tag', () {
      expect(summary.license, equals('bsd-3-clause'));
    });

    test('isFlutterFavorite is false when is:flutter-favorite tag absent', () {
      expect(summary.isFlutterFavorite, isFalse);
    });

    test('isFlutterFavorite is true when is:flutter-favorite tag present', () {
      final scoreWithFav = {
        ...packageScore,
        'tags': [...(packageScore['tags']! as List<Object?>), 'is:flutter-favorite'],
      };
      final s = PackageSummary.fromPackageAndScore(
        packageInfo,
        scoreWithFav,
        now: fixedNow,
      );
      expect(s.isFlutterFavorite, isTrue);
    });

    test('daysSinceUpdate is computed from latest.published', () {
      // http 1.6.0 published 2025-11-10T18:27Z; fixedNow = 2026-05-10T00:00Z
      // = 180 whole days (inDays truncates the remaining ~5.5 hours)
      expect(summary.daysSinceUpdate, equals(180));
    });

    test('activeMaintenance is true when daysSinceUpdate is less than 365', () {
      expect(summary.activeMaintenance, isTrue);
    });

    test('activeMaintenance is true when pubPoints is at least 130 even if stale', () {
      // Simulate a package published > 365 days ago but with 160 pub points.
      final oldInfo = <String, Object?>{
        ...packageInfo,
        'latest': <String, Object?>{
          ...(packageInfo['latest']! as Map<String, Object?>),
          'published': '2020-01-01T00:00:00Z',
        },
      };
      final s = PackageSummary.fromPackageAndScore(
        oldInfo,
        packageScore,
        now: fixedNow,
      );
      expect(s.activeMaintenance, isTrue);
    });

    test('activeMaintenance is false when stale and pubPoints is below 130', () {
      final oldInfo = <String, Object?>{
        ...packageInfo,
        'latest': <String, Object?>{
          ...(packageInfo['latest']! as Map<String, Object?>),
          'published': '2020-01-01T00:00:00Z',
        },
      };
      final lowScore = <String, Object?>{...packageScore, 'grantedPoints': 100};
      final s = PackageSummary.fromPackageAndScore(
        oldInfo,
        lowScore,
        now: fixedNow,
      );
      expect(s.activeMaintenance, isFalse);
    });

    test('verified is false when no publisher tag is present', () {
      final scoreNoPublisher = <String, Object?>{
        ...packageScore,
        'tags': (packageScore['tags']! as List<Object?>)
            .where((t) => !(t! as String).startsWith('publisher:'))
            .toList(),
      };
      final s = PackageSummary.fromPackageAndScore(packageInfo, scoreNoPublisher);
      expect(s.verified, isFalse);
    });

    test('publisher is null when no publisher tag is present', () {
      final scoreNoPublisher = <String, Object?>{
        ...packageScore,
        'tags': (packageScore['tags']! as List<Object?>)
            .where((t) => !(t! as String).startsWith('publisher:'))
            .toList(),
      };
      final s = PackageSummary.fromPackageAndScore(packageInfo, scoreNoPublisher);
      expect(s.publisher, isNull);
    });

    test('copyWith replaces version', () {
      expect(summary.copyWith(version: '2.0.0').version, equals('2.0.0'));
    });

    test('copyWith leaves other fields unchanged', () {
      expect(summary.copyWith(version: '2.0.0').name, equals(summary.name));
    });
  });

  // ─── PackageDetail ────────────────────────────────────────────────────────

  group('PackageDetail.fromPackageAndScore', () {
    late PackageDetail detail;

    setUp(() {
      detail = PackageDetail.fromPackageAndScore(
        packageInfo,
        packageScore,
        now: fixedNow,
      );
    });

    test('name is parsed from package info', () {
      expect(detail.name, equals('http'));
    });

    test('publishedAt is parsed from latest.published', () {
      expect(
        detail.publishedAt,
        equals(DateTime.parse('2025-11-10T18:27:56.434747Z')),
      );
    });

    test('score.likes equals likeCount', () {
      expect(detail.score.likes, equals(8435));
    });

    test('sdkConstraints.dart is from pubspec environment.sdk', () {
      expect(detail.sdkConstraints.dart, equals('^3.4.0'));
    });

    test('sdkConstraints.flutter is null for a non-flutter-only package', () {
      expect(detail.sdkConstraints.flutter, isNull);
    });

    test('dependencies map contains async', () {
      expect(detail.dependencies, containsPair('async', '^2.5.0'));
    });

    test('devDependencies map contains test', () {
      expect(detail.devDependencies, contains('test'));
    });

    test('repository is parsed from pubspec', () {
      expect(
        detail.repository,
        equals('https://github.com/dart-lang/http/tree/master/pkgs/http'),
      );
    });

    test('versionsRecent contains at most 5 entries', () {
      expect(detail.versionsRecent.length, lessThanOrEqualTo(5));
    });

    test('versionsRecent first entry is the latest version', () {
      expect(detail.versionsRecent.first, equals('1.6.0'));
    });

    test('readmeExcerpt is set when provided', () {
      final d = PackageDetail.fromPackageAndScore(
        packageInfo,
        packageScore,
        readmeExcerpt: 'A great library.',
      );
      expect(d.readmeExcerpt, equals('A great library.'));
    });

    test('readmeExcerpt is null when not provided', () {
      expect(detail.readmeExcerpt, isNull);
    });

    test('publishedAt is null when the published field is absent', () {
      final d = PackageDetail.fromPackageAndScore(
        {
          ...packageInfo,
          'latest': <String, Object?>{
            ...(packageInfo['latest']! as Map<String, Object?>),
            'published': null,
          },
        },
        packageScore,
      );
      expect(d.publishedAt, isNull);
    });

    test('publishedAt is null when the published value is unparseable', () {
      final d = PackageDetail.fromPackageAndScore(
        {
          ...packageInfo,
          'latest': <String, Object?>{
            ...(packageInfo['latest']! as Map<String, Object?>),
            'published': 'not-a-date',
          },
        },
        packageScore,
      );
      expect(d.publishedAt, isNull);
    });

    test('copyWith replaces description', () {
      expect(
        detail.copyWith(description: 'New desc').description,
        equals('New desc'),
      );
    });

    test('copyWith leaves other fields unchanged', () {
      expect(detail.copyWith(description: 'X').name, equals(detail.name));
    });
  });

  // ─── PackageMetrics ───────────────────────────────────────────────────────

  group('PackageMetrics.fromJson', () {
    late PackageMetrics metrics;

    setUp(() {
      metrics = PackageMetrics.fromJson(packageMetrics);
    });

    test('score.pubPoints is parsed correctly', () {
      expect(metrics.score.pubPoints, equals(160));
    });

    test('packageVersion matches fixture', () {
      expect(metrics.packageVersion, equals('1.6.0'));
    });

    test('reportStatus is success', () {
      expect(metrics.reportStatus, equals('success'));
    });

    test('updated is a valid DateTime', () {
      expect(metrics.updated?.year, equals(2026));
    });

    test('copyWith replaces reportStatus', () {
      expect(
        metrics.copyWith(reportStatus: 'failed').reportStatus,
        equals('failed'),
      );
    });

    test('updated is null when the field is absent', () {
      final m = PackageMetrics.fromJson(const {});
      expect(m.updated, isNull);
    });

    test('updated is null when the date is unparseable', () {
      final m = PackageMetrics.fromJson({
        'scorecard': {'updated': 'not-a-date'},
      });
      expect(m.updated, isNull);
    });
  });

  // ─── ChangelogEntry ───────────────────────────────────────────────────────

  group('ChangelogEntry.fromJson', () {
    test('version is parsed', () {
      final entry = ChangelogEntry.fromJson({
        'version': '1.0.0',
        'date': '2024-01-01T00:00:00Z',
        'changes': 'Initial release.',
        'breaking': false,
      });
      expect(entry.version, equals('1.0.0'));
    });

    test('date is parsed as DateTime', () {
      final entry = ChangelogEntry.fromJson({
        'version': '1.0.0',
        'date': '2024-06-15T00:00:00Z',
        'changes': '',
        'breaking': false,
      });
      expect(entry.date, equals(DateTime.parse('2024-06-15T00:00:00Z')));
    });

    test('breaking flag is preserved', () {
      final entry = ChangelogEntry.fromJson({
        'version': '2.0.0',
        'date': '2024-01-01',
        'changes': 'BREAKING: removed old API.',
        'breaking': true,
      });
      expect(entry.breaking, isTrue);
    });

    test('breaking defaults to false when absent', () {
      final entry = ChangelogEntry.fromJson({
        'version': '1.0.0',
        'date': '2024-01-01',
        'changes': 'Minor fix.',
      });
      expect(entry.breaking, isFalse);
    });

    test('date is null when the field is absent', () {
      final entry = ChangelogEntry.fromJson({
        'version': '1.0.0',
        'changes': '',
        'breaking': false,
      });
      expect(entry.date, isNull);
    });

    test('date is null when the value is unparseable', () {
      final entry = ChangelogEntry.fromJson({
        'version': '1.0.0',
        'date': 'not-a-date',
        'changes': '',
        'breaking': false,
      });
      expect(entry.date, isNull);
    });

    test('copyWith replaces changes', () {
      final base = ChangelogEntry.fromJson({
        'version': '1.0.0',
        'date': '2024-01-01',
        'changes': 'Old.',
        'breaking': false,
      });
      expect(base.copyWith(changes: 'New.').changes, equals('New.'));
    });
  });

  // ─── DartdocSymbol ────────────────────────────────────────────────────────

  group('DartdocSymbol.fromJson', () {
    test('name is parsed', () {
      final sym = DartdocSymbol.fromJson(indexJson.first! as Map<String, Object?>);
      expect(sym.name, isNotEmpty);
    });

    test('qualifiedName is parsed', () {
      final sym = DartdocSymbol.fromJson(indexJson.first! as Map<String, Object?>);
      expect(sym.qualifiedName, isNotEmpty);
    });

    test('href is parsed', () {
      final sym = DartdocSymbol.fromJson(indexJson.first! as Map<String, Object?>);
      expect(sym.href, isNotEmpty);
    });

    test('kind 9 maps to type "library"', () {
      final sym = DartdocSymbol.fromJson({
        'name': 'x',
        'qualifiedName': 'x',
        'href': 'x/',
        'kind': 9,
        'desc': '',
      });
      expect(sym.type, equals('library'));
    });

    test('kind 3 maps to type "class"', () {
      final sym = DartdocSymbol.fromJson({
        'name': 'X',
        'qualifiedName': 'x.X',
        'href': 'x/X.html',
        'kind': 3,
        'desc': '',
      });
      expect(sym.type, equals('class'));
    });

    test('kind 10 maps to type "method"', () {
      final sym = DartdocSymbol.fromJson({
        'name': 'foo',
        'qualifiedName': 'x.foo',
        'href': 'x/foo.html',
        'kind': 10,
        'desc': '',
      });
      expect(sym.type, equals('method'));
    });

    test('kind 2 maps to type "constructor"', () {
      final sym = DartdocSymbol.fromJson({
        'name': 'X.new',
        'qualifiedName': 'x.X.new',
        'href': 'x/X/X.html',
        'kind': 2,
        'desc': '',
      });
      expect(sym.type, equals('constructor'));
    });

    test('unknown kind passes through as its string representation', () {
      final sym = DartdocSymbol.fromJson({
        'name': 'x',
        'qualifiedName': 'x',
        'href': 'x',
        'kind': 99,
        'desc': '',
      });
      expect(sym.type, equals('99'));
    });

    test('desc is parsed', () {
      final sym = DartdocSymbol.fromJson({
        'name': 'x',
        'qualifiedName': 'x',
        'href': 'x',
        'kind': 9,
        'desc': 'A library.',
      });
      expect(sym.desc, equals('A library.'));
    });

    test('copyWith replaces desc', () {
      final base = DartdocSymbol.fromJson({
        'name': 'x',
        'qualifiedName': 'x',
        'href': 'x',
        'kind': 9,
        'desc': 'Old.',
      });
      expect(base.copyWith(desc: 'New.').desc, equals('New.'));
    });

    test('copyWith leaves other fields unchanged', () {
      final base = DartdocSymbol.fromJson({
        'name': 'x',
        'qualifiedName': 'x',
        'href': 'x',
        'kind': 9,
        'desc': 'Old.',
      });
      expect(base.copyWith(desc: 'New.').type, equals(base.type));
    });
  });
}
