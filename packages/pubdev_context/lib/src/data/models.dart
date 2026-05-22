/// Response models for pub.dev API data.
///
/// Pure, immutable data classes with no framework dependencies.
/// Computed fields ([PackageSummary.activeMaintenance],
/// [PackageSummary.isFlutterFavorite]) are derived from raw pub.dev response
/// data during construction.
library;

// ─── Helpers ─────────────────────────────────────────────────────────────────

String? _optStr(Map<String, Object?> map, String key) => map[key] as String?;

Map<String, Object?> _subMap(Map<String, Object?> map, String key) =>
    (map[key] as Map<String, Object?>?) ?? const {};

List<String> _strList(Map<String, Object?> map, String key) =>
    ((map[key] as List<Object?>?) ?? const []).whereType<String>().toList();

Map<String, String> _strMap(Map<String, Object?> map, String key) {
  final raw = _subMap(map, key);
  final result = <String, String>{};
  for (final entry in raw.entries) {
    final value = entry.value;
    if (value is String) result[entry.key] = value;
  }
  return result;
}

List<String> _tagsWithPrefix(List<String> tags, String prefix) =>
    tags.where((t) => t.startsWith(prefix)).map((t) => t.substring(prefix.length)).toList();

int _daysSince(String? published, DateTime? now) {
  if (published == null) return 0;
  final date = DateTime.tryParse(published);
  if (date == null) return 0;
  return (now ?? DateTime.now()).difference(date).inDays;
}

// ─── PackageScore ─────────────────────────────────────────────────────────────

/// Aggregated quality and popularity scores for a pub.dev package.
///
/// Sourced from the `GET /api/packages/{name}/score` endpoint. [popularity]
/// is the 30-day download count.
final class PackageScore {
  /// Creates a [PackageScore] with the given fields.
  const PackageScore({
    required this.likes,
    required this.pubPoints,
    required this.popularity,
  });

  /// Constructs a [PackageScore] from a `/api/packages/{name}/score` response.
  factory PackageScore.fromJson(Map<String, Object?> json) => PackageScore(
    likes: (json['likeCount'] as int?) ?? 0,
    pubPoints: (json['grantedPoints'] as int?) ?? 0,
    popularity: (json['downloadCount30Days'] as int?) ?? 0,
  );

  /// The total number of likes the package has received.
  final int likes;

  /// The pub points score (0–160).
  final int pubPoints;

  /// The 30-day download count used as a popularity proxy.
  final int popularity;

  /// Returns a copy of this score with the given fields replaced.
  PackageScore copyWith({int? likes, int? pubPoints, int? popularity}) => PackageScore(
    likes: likes ?? this.likes,
    pubPoints: pubPoints ?? this.pubPoints,
    popularity: popularity ?? this.popularity,
  );
}

// ─── SdkConstraints ──────────────────────────────────────────────────────────

/// SDK version constraints declared in a package's pubspec.
///
/// [dart] is always present; [flutter] is only set when the package requires
/// a specific Flutter SDK version.
final class SdkConstraints {
  /// Creates [SdkConstraints] with the given constraint strings.
  const SdkConstraints({required this.dart, this.flutter});

  /// Constructs [SdkConstraints] from a pubspec `environment` map.
  factory SdkConstraints.fromJson(Map<String, Object?> json) => SdkConstraints(
    dart: _optStr(json, 'sdk') ?? '>=3.0.0 <4.0.0',
    flutter: _optStr(json, 'flutter'),
  );

  /// The Dart SDK version constraint (e.g. `"^3.4.0"`).
  final String dart;

  /// The Flutter SDK version constraint, or `null` when not specified.
  final String? flutter;

  /// Returns a copy of these constraints with the given fields replaced.
  SdkConstraints copyWith({String? dart, String? flutter}) => SdkConstraints(
    dart: dart ?? this.dart,
    flutter: flutter ?? this.flutter,
  );
}

// ─── PackageSummary ───────────────────────────────────────────────────────────

/// Compact package view returned by search and compare operations.
///
/// Combines data from the `/api/packages/{name}` and
/// `/api/packages/{name}/score` endpoints. [activeMaintenance] and
/// [isFlutterFavorite] are derived fields — no additional HTTP calls are made.
final class PackageSummary {
  /// Creates a [PackageSummary] with the given fields.
  ///
  /// Required parameters must precede optional ones in call sites; use
  /// [PackageSummary.fromPackageAndScore] to build from raw API responses.
  const PackageSummary({
    required this.name,
    required this.version,
    required this.description,
    required this.likes,
    required this.pubPoints,
    required this.popularity,
    required this.verified,
    required this.sdks,
    required this.platforms,
    required this.topics,
    required this.isFlutterFavorite,
    required this.daysSinceUpdate,
    required this.activeMaintenance,
    this.publisher,
    this.license,
  });

  /// Builds a [PackageSummary] from a package-info response and a score response.
  ///
  /// [packageInfo] is the body of `GET /api/packages/{name}`.
  /// [score] is the body of `GET /api/packages/{name}/score`.
  /// [now] overrides the current time; useful for deterministic tests.
  factory PackageSummary.fromPackageAndScore(
    Map<String, Object?> packageInfo,
    Map<String, Object?> score, {
    DateTime? now,
  }) {
    final latest = _subMap(packageInfo, 'latest');
    final pubspec = _subMap(latest, 'pubspec');
    final tags = _strList(score, 'tags');
    final published = _optStr(latest, 'published');
    final daysSince = _daysSince(published, now);
    final pubPoints = (score['grantedPoints'] as int?) ?? 0;
    final licenses = _tagsWithPrefix(tags, 'license:');

    return PackageSummary(
      name: _optStr(packageInfo, 'name') ?? '',
      version: _optStr(latest, 'version') ?? '',
      description: _optStr(pubspec, 'description') ?? '',
      likes: (score['likeCount'] as int?) ?? 0,
      pubPoints: pubPoints,
      popularity: (score['downloadCount30Days'] as int?) ?? 0,
      verified: _tagsWithPrefix(tags, 'publisher:').isNotEmpty,
      sdks: _tagsWithPrefix(tags, 'sdk:'),
      platforms: _tagsWithPrefix(tags, 'platform:'),
      topics: _strList(pubspec, 'topics'),
      isFlutterFavorite: tags.contains('is:flutter-favorite'),
      daysSinceUpdate: daysSince,
      activeMaintenance: daysSince < 365 || pubPoints >= 130,
      publisher: _tagsWithPrefix(tags, 'publisher:').firstOrNull,
      license: licenses.firstOrNull,
    );
  }

  /// The package name on pub.dev.
  final String name;

  /// The latest stable version string (e.g. `"1.6.0"`).
  final String version;

  /// The short package description from the pubspec.
  final String description;

  /// Total number of likes.
  final int likes;

  /// Pub points score (0–160).
  final int pubPoints;

  /// 30-day download count used as a popularity proxy.
  final int popularity;

  /// Whether the package belongs to a verified publisher.
  final bool verified;

  /// SDK compatibility tags (e.g. `["dart", "flutter"]`).
  final List<String> sdks;

  /// Supported platform tags (e.g. `["android", "ios", "web"]`).
  final List<String> platforms;

  /// Topic tags declared in the pubspec.
  final List<String> topics;

  /// Whether the package carries the Flutter Favourite designation.
  ///
  /// Derived from the `is:flutter-favorite` score tag — no extra HTTP call.
  final bool isFlutterFavorite;

  /// Days elapsed since the latest version was published.
  final int daysSinceUpdate;

  /// Whether the package is considered actively maintained.
  ///
  /// `true` when [daysSinceUpdate] is less than 365, or [pubPoints] is at
  /// least 130.
  final bool activeMaintenance;

  /// The verified publisher domain (e.g. `"dart.dev"`), or `null`.
  final String? publisher;

  /// The first SPDX license identifier from the score tags, or `null`.
  final String? license;

  /// Returns a copy of this summary with the given fields replaced.
  PackageSummary copyWith({
    String? name,
    String? version,
    String? description,
    int? likes,
    int? pubPoints,
    int? popularity,
    bool? verified,
    List<String>? sdks,
    List<String>? platforms,
    List<String>? topics,
    bool? isFlutterFavorite,
    int? daysSinceUpdate,
    bool? activeMaintenance,
    String? publisher,
    String? license,
  }) => PackageSummary(
    name: name ?? this.name,
    version: version ?? this.version,
    description: description ?? this.description,
    likes: likes ?? this.likes,
    pubPoints: pubPoints ?? this.pubPoints,
    popularity: popularity ?? this.popularity,
    verified: verified ?? this.verified,
    sdks: sdks ?? this.sdks,
    platforms: platforms ?? this.platforms,
    topics: topics ?? this.topics,
    isFlutterFavorite: isFlutterFavorite ?? this.isFlutterFavorite,
    daysSinceUpdate: daysSinceUpdate ?? this.daysSinceUpdate,
    activeMaintenance: activeMaintenance ?? this.activeMaintenance,
    publisher: publisher ?? this.publisher,
    license: license ?? this.license,
  );
}

// ─── PackageDetail ────────────────────────────────────────────────────────────

/// Full package view returned by the `get_package` tool.
///
/// Combines data from `/api/packages/{name}`, `/api/packages/{name}/score`,
/// and the rendered documentation page. [isFlutterFavorite] and [license] are
/// derived from the score tags — no extra HTTP calls.
final class PackageDetail {
  /// Creates a [PackageDetail] with the given fields.
  const PackageDetail({
    required this.name,
    required this.version,
    required this.description,
    required this.verified,
    required this.publishedAt,
    required this.activeMaintenance,
    required this.score,
    required this.sdkConstraints,
    required this.platforms,
    required this.topics,
    required this.isFlutterFavorite,
    required this.dependencies,
    required this.devDependencies,
    required this.versionsRecent,
    this.publisher,
    this.license,
    this.readmeExcerpt,
    this.repository,
  });

  /// Builds a [PackageDetail] from a package-info response and a score response.
  ///
  /// [packageInfo] is the body of `GET /api/packages/{name}`.
  /// [score] is the body of `GET /api/packages/{name}/score`.
  /// [readmeExcerpt] is the extracted text snippet from the docs page.
  /// [now] overrides the current time for deterministic tests.
  factory PackageDetail.fromPackageAndScore(
    Map<String, Object?> packageInfo,
    Map<String, Object?> score, {
    String? readmeExcerpt,
    DateTime? now,
  }) {
    final latest = _subMap(packageInfo, 'latest');
    final pubspec = _subMap(latest, 'pubspec');
    final tags = _strList(score, 'tags');
    final published = _optStr(latest, 'published');
    final daysSince = _daysSince(published, now);
    final pubPoints = (score['grantedPoints'] as int?) ?? 0;
    final licenses = _tagsWithPrefix(tags, 'license:');
    final rawVersions = (packageInfo['versions'] as List<Object?>?) ?? const [];
    final recentVersions = rawVersions.reversed
        .take(5)
        .cast<Map<String, Object?>>()
        .map((v) => _optStr(v, 'version') ?? '')
        .where((v) => v.isNotEmpty)
        .toList();
    final publishedAt = published != null ? DateTime.tryParse(published) : null;

    return PackageDetail(
      name: _optStr(packageInfo, 'name') ?? '',
      version: _optStr(latest, 'version') ?? '',
      description: _optStr(pubspec, 'description') ?? '',
      verified: _tagsWithPrefix(tags, 'publisher:').isNotEmpty,
      publishedAt: publishedAt,
      activeMaintenance: daysSince < 365 || pubPoints >= 130,
      score: PackageScore.fromJson(score),
      sdkConstraints: SdkConstraints.fromJson(_subMap(pubspec, 'environment')),
      platforms: _tagsWithPrefix(tags, 'platform:'),
      topics: _strList(pubspec, 'topics'),
      isFlutterFavorite: tags.contains('is:flutter-favorite'),
      dependencies: _strMap(pubspec, 'dependencies'),
      devDependencies: _strMap(pubspec, 'dev_dependencies'),
      versionsRecent: recentVersions,
      publisher: _tagsWithPrefix(tags, 'publisher:').firstOrNull,
      license: licenses.firstOrNull,
      readmeExcerpt: readmeExcerpt,
      repository: _optStr(pubspec, 'repository'),
    );
  }

  /// The package name on pub.dev.
  final String name;

  /// The latest stable version string.
  final String version;

  /// The short package description from the pubspec.
  final String description;

  /// Whether the package belongs to a verified publisher.
  final bool verified;

  /// When the latest version was published, or `null` when the field is absent or unparseable.
  final DateTime? publishedAt;

  /// Whether the package is considered actively maintained.
  final bool activeMaintenance;

  /// Aggregated quality and popularity scores.
  final PackageScore score;

  /// SDK version constraints from the pubspec environment.
  final SdkConstraints sdkConstraints;

  /// Supported platform tags.
  final List<String> platforms;

  /// Topic tags from the pubspec.
  final List<String> topics;

  /// Whether the package carries the Flutter Favourite designation.
  final bool isFlutterFavorite;

  /// Runtime dependencies keyed by package name, with version constraints.
  final Map<String, String> dependencies;

  /// Development dependencies keyed by package name, with version constraints.
  final Map<String, String> devDependencies;

  /// The five most recent version strings, newest first.
  final List<String> versionsRecent;

  /// The verified publisher domain, or `null` for individual publishers.
  final String? publisher;

  /// The first SPDX license identifier from the score tags, or `null`.
  final String? license;

  /// A short text excerpt from the package README, or `null` when unavailable.
  final String? readmeExcerpt;

  /// The VCS repository URL from the pubspec, or `null`.
  final String? repository;

  /// Returns a copy of this detail with the given fields replaced.
  PackageDetail copyWith({
    String? name,
    String? version,
    String? description,
    bool? verified,
    DateTime? publishedAt,
    bool? activeMaintenance,
    PackageScore? score,
    SdkConstraints? sdkConstraints,
    List<String>? platforms,
    List<String>? topics,
    bool? isFlutterFavorite,
    Map<String, String>? dependencies,
    Map<String, String>? devDependencies,
    List<String>? versionsRecent,
    String? publisher,
    String? license,
    String? readmeExcerpt,
    String? repository,
  }) => PackageDetail(
    name: name ?? this.name,
    version: version ?? this.version,
    description: description ?? this.description,
    verified: verified ?? this.verified,
    publishedAt: publishedAt ?? this.publishedAt,
    activeMaintenance: activeMaintenance ?? this.activeMaintenance,
    score: score ?? this.score,
    sdkConstraints: sdkConstraints ?? this.sdkConstraints,
    platforms: platforms ?? this.platforms,
    topics: topics ?? this.topics,
    isFlutterFavorite: isFlutterFavorite ?? this.isFlutterFavorite,
    dependencies: dependencies ?? this.dependencies,
    devDependencies: devDependencies ?? this.devDependencies,
    versionsRecent: versionsRecent ?? this.versionsRecent,
    publisher: publisher ?? this.publisher,
    license: license ?? this.license,
    readmeExcerpt: readmeExcerpt ?? this.readmeExcerpt,
    repository: repository ?? this.repository,
  );
}

// ─── PackageMetrics ───────────────────────────────────────────────────────────

/// Full metrics data for a pub.dev package.
///
/// Sourced from `GET /api/packages/{name}/metrics`. Includes the [score] and
/// scorecard metadata.
final class PackageMetrics {
  /// Creates a [PackageMetrics] with the given fields.
  const PackageMetrics({
    required this.score,
    required this.packageVersion,
    required this.updated,
    required this.reportStatus,
  });

  /// Constructs a [PackageMetrics] from a `/api/packages/{name}/metrics` response.
  factory PackageMetrics.fromJson(Map<String, Object?> json) {
    final scoreMap = _subMap(json, 'score');
    final scorecard = _subMap(json, 'scorecard');
    final pana = _subMap(scorecard, 'panaReport');
    return PackageMetrics(
      score: PackageScore.fromJson(scoreMap),
      packageVersion: _optStr(scorecard, 'packageVersion') ?? '',
      updated: DateTime.tryParse(_optStr(scorecard, 'updated') ?? ''),
      reportStatus: _optStr(pana, 'reportStatus') ?? '',
    );
  }

  /// Aggregated quality and popularity scores.
  final PackageScore score;

  /// The package version analysed in this scorecard.
  final String packageVersion;

  /// When this scorecard was last updated, or `null` when the field is absent or unparseable.
  final DateTime? updated;

  /// The pana analysis report status (e.g. `"success"`).
  final String reportStatus;

  /// Returns a copy of these metrics with the given fields replaced.
  PackageMetrics copyWith({
    PackageScore? score,
    String? packageVersion,
    DateTime? updated,
    String? reportStatus,
  }) => PackageMetrics(
    score: score ?? this.score,
    packageVersion: packageVersion ?? this.packageVersion,
    updated: updated ?? this.updated,
    reportStatus: reportStatus ?? this.reportStatus,
  );
}

// ─── ChangelogEntry ───────────────────────────────────────────────────────────

/// A single version entry from a package changelog.
///
/// [breaking] is `true` when the entry text contains explicit breaking-change
/// markers (e.g. `BREAKING`, `BREAKING CHANGE`).
final class ChangelogEntry {
  /// Creates a [ChangelogEntry] with the given fields.
  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.changes,
    required this.breaking,
  });

  /// Constructs a [ChangelogEntry] from a parsed changelog map.
  factory ChangelogEntry.fromJson(Map<String, Object?> json) => ChangelogEntry(
    version: _optStr(json, 'version') ?? '',
    date: DateTime.tryParse(_optStr(json, 'date') ?? ''),
    changes: _optStr(json, 'changes') ?? '',
    breaking: (json['breaking'] as bool?) ?? false,
  );

  /// The version string for this changelog entry (e.g. `"1.6.0"`).
  final String version;

  /// The release date for this version, or `null` when the field is absent or unparseable.
  final DateTime? date;

  /// The changelog text for this version.
  final String changes;

  /// Whether this version contains breaking changes.
  final bool breaking;

  /// Returns a copy of this entry with the given fields replaced.
  ChangelogEntry copyWith({
    String? version,
    DateTime? date,
    String? changes,
    bool? breaking,
  }) => ChangelogEntry(
    version: version ?? this.version,
    date: date ?? this.date,
    changes: changes ?? this.changes,
    breaking: breaking ?? this.breaking,
  );
}

// ─── DartdocSymbol ────────────────────────────────────────────────────────────

/// One element from a dartdoc `index.json` file.
///
/// [type] is a human-readable string derived from the numeric `kind` field in
/// the raw JSON. Unknown `kind` values are passed through as their string
/// representation so new dartdoc kinds are never silently dropped.
final class DartdocSymbol {
  /// Creates a [DartdocSymbol] with the given fields.
  const DartdocSymbol({
    required this.name,
    required this.qualifiedName,
    required this.href,
    required this.type,
    required this.desc,
  });

  /// Constructs a [DartdocSymbol] from a single entry in `index.json`.
  ///
  /// The raw `kind` integer is mapped to a readable [type] string; any
  /// unrecognised value is kept as its decimal string representation.
  factory DartdocSymbol.fromJson(Map<String, Object?> json) => DartdocSymbol(
    name: _optStr(json, 'name') ?? '',
    qualifiedName: _optStr(json, 'qualifiedName') ?? '',
    href: _optStr(json, 'href') ?? '',
    type: _kindToType((json['kind'] as int?) ?? -1),
    desc: _optStr(json, 'desc') ?? '',
  );

  /// The short symbol name (e.g. `"Client"`).
  final String name;

  /// The fully-qualified symbol name (e.g. `"http.Client"`).
  final String qualifiedName;

  /// The relative URL path to the symbol's dartdoc page.
  final String href;

  /// A human-readable symbol kind (e.g. `"class"`, `"method"`).
  ///
  /// Unknown `kind` values from newer dartdoc versions are preserved as-is.
  final String type;

  /// The short description from the dartdoc comment, if any.
  final String desc;

  /// Returns a copy of this symbol with the given fields replaced.
  DartdocSymbol copyWith({
    String? name,
    String? qualifiedName,
    String? href,
    String? type,
    String? desc,
  }) => DartdocSymbol(
    name: name ?? this.name,
    qualifiedName: qualifiedName ?? this.qualifiedName,
    href: href ?? this.href,
    type: type ?? this.type,
    desc: desc ?? this.desc,
  );

  // Ordinal positions from dartdoc's Kind enum (lib/src/model/kind.dart).
  static String _kindToType(int kind) => switch (kind) {
    0 => 'accessor',
    1 => 'constant',
    2 => 'constructor',
    3 => 'class',
    4 => 'dynamic',
    5 => 'enum',
    6 => 'extension',
    7 => 'extension-type',
    8 => 'function',
    9 => 'library',
    10 => 'method',
    11 => 'mixin',
    12 => 'never',
    13 => 'package',
    14 => 'parameter',
    15 => 'prefix',
    16 => 'property',
    17 => 'sdk',
    18 => 'topic',
    19 => 'top-level-constant',
    20 => 'top-level-property',
    21 => 'typedef',
    22 => 'type-parameter',
    _ => kind.toString(),
  };
}
