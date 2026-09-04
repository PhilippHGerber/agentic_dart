/// Response models for pub.dev API data.
///
/// Pure, immutable data classes with no framework dependencies.
/// Computed fields ([PackageSummary.activeMaintenance],
/// [PackageSummary.isFlutterFavorite]) are derived from raw pub.dev response
/// data during construction.
library;

// ─── Helpers ─────────────────────────────────────────────────────────────────

String? _optStr(Map<String, Object?> map, String key) => map[key] as String?;

/// The deterministic pub.dev archive download URL for [name] at [version].
///
/// Shared by [PackageDetail.fromPackageAndScore] (as `archiveUrl`) and
/// `PubDevClient.getPackageSourceFiles` (the URL it downloads) so the two
/// call sites never drift apart.
String packageArchiveUrl(String name, String version) =>
    'https://pub.dev/api/packages/$name/versions/$version/archive.tar.gz';

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

Map<String, List<String>> _sectionsMap(Map<String, Object?> map, String key) {
  final raw = _subMap(map, key);
  final result = <String, List<String>>{};
  for (final entry in raw.entries) {
    final value = entry.value;
    if (value is List<Object?>) {
      result[entry.key] = value.whereType<String>().toList();
    }
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
    required this.archiveUrl,
    this.publisher,
    this.license,
    this.readmeExcerpt,
    this.repository,
    this.homepage,
    this.issueTracker,
    this.documentation,
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
    final name = _optStr(packageInfo, 'name') ?? '';
    final version = _optStr(latest, 'version') ?? '';

    return PackageDetail(
      name: name,
      version: version,
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
      archiveUrl: packageArchiveUrl(name, version),
      homepage: _optStr(pubspec, 'homepage'),
      issueTracker: _optStr(pubspec, 'issue_tracker'),
      documentation: _optStr(pubspec, 'documentation'),
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

  /// Direct download URL of the published `.tar.gz` for [version].
  ///
  /// Deterministic — computed via [packageArchiveUrl] rather than read from
  /// the pubspec — and always present, unlike the other source-metadata
  /// fields.
  final String archiveUrl;

  /// The `homepage` URL from the pubspec, or `null`.
  final String? homepage;

  /// The `issue_tracker` URL from the pubspec, or `null`.
  final String? issueTracker;

  /// The `documentation` URL from the pubspec, or `null`.
  final String? documentation;

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
    String? archiveUrl,
    String? homepage,
    String? issueTracker,
    String? documentation,
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
    archiveUrl: archiveUrl ?? this.archiveUrl,
    homepage: homepage ?? this.homepage,
    issueTracker: issueTracker ?? this.issueTracker,
    documentation: documentation ?? this.documentation,
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

// ─── PackageVersion ───────────────────────────────────────────────────────────

/// A single published version of a package.
///
/// Sourced from one entry of the `versions` array in the
/// `GET /api/packages/{name}` response. [retracted] reflects version-level
/// retraction from pub.dev; package-level discontinuation is not represented
/// here. [isPrerelease] is derived from the semver string.
final class PackageVersion {
  /// Creates a [PackageVersion] with the given fields.
  const PackageVersion({
    required this.version,
    required this.publishedAt,
    required this.retracted,
  });

  /// Constructs a [PackageVersion] from one entry of the `versions` array.
  ///
  /// The `retracted` flag is absent from pub.dev responses for versions that
  /// have not been retracted; a missing value is treated as `false`.
  factory PackageVersion.fromJson(Map<String, Object?> json) => PackageVersion(
    version: _optStr(json, 'version') ?? '',
    publishedAt: DateTime.tryParse(_optStr(json, 'published') ?? ''),
    retracted: (json['retracted'] as bool?) ?? false,
  );

  /// The semver version string (e.g. `"1.2.0"` or `"1.3.0-beta.1"`).
  final String version;

  /// When this version was published, or `null` when the field is absent or unparseable.
  final DateTime? publishedAt;

  /// Whether this version has been retracted on pub.dev.
  final bool retracted;

  /// Whether this version is a pre-release (its semver carries a `-` suffix).
  bool get isPrerelease => version.contains('-');

  /// Returns a copy of this version with the given fields replaced.
  PackageVersion copyWith({String? version, DateTime? publishedAt, bool? retracted}) =>
      PackageVersion(
        version: version ?? this.version,
        publishedAt: publishedAt ?? this.publishedAt,
        retracted: retracted ?? this.retracted,
      );
}

// ─── ChangelogEntry ───────────────────────────────────────────────────────────

/// A single version entry from a package changelog.
///
/// [changes] is the parsed list of change bullet/item strings for this version.
/// [rawText] is the raw unparsed changelog section text for this version.
/// [breaking] is `true` when the entry text contains explicit breaking-change
/// markers (e.g. `BREAKING`, `BREAKING CHANGE`).
final class ChangelogEntry {
  /// Creates a [ChangelogEntry] with the given fields.
  const ChangelogEntry({
    required this.version,
    required this.date,
    required this.changes,
    required this.rawText,
    required this.breaking,
  });

  /// Constructs a [ChangelogEntry] from a parsed changelog map.
  factory ChangelogEntry.fromJson(Map<String, Object?> json) => ChangelogEntry(
    version: _optStr(json, 'version') ?? '',
    date: DateTime.tryParse(_optStr(json, 'date') ?? ''),
    changes: switch (json['changes']) {
      final List<Object?> l => l.whereType<String>().toList(),
      final String s when s.isNotEmpty => [s],
      _ => const <String>[],
    },
    rawText: _optStr(json, 'rawText') ?? '',
    breaking: (json['breaking'] as bool?) ?? false,
  );

  /// The version string for this changelog entry (e.g. `"1.6.0"`).
  final String version;

  /// The release date for this version, or `null` when the field is absent or unparseable.
  final DateTime? date;

  /// The parsed list of change bullet/item strings for this version.
  final List<String> changes;

  /// The raw unparsed changelog section text for this version.
  final String rawText;

  /// Whether this version contains breaking changes.
  final bool breaking;

  /// Returns a copy of this entry with the given fields replaced.
  ChangelogEntry copyWith({
    String? version,
    DateTime? date,
    List<String>? changes,
    String? rawText,
    bool? breaking,
  }) => ChangelogEntry(
    version: version ?? this.version,
    date: date ?? this.date,
    changes: changes ?? this.changes,
    rawText: rawText ?? this.rawText,
    breaking: breaking ?? this.breaking,
  );
}

// ─── SdkReleaseNotesEntry ───────────────────────────────────────────────────

/// A single version entry from an SDK changelog or release notes document.
///
/// [breaking] is `true` when the entry text or section names contain explicit
/// breaking-change markers (e.g. `Breaking changes`, `BREAKING`).
final class SdkReleaseNotesEntry {
  /// Creates an [SdkReleaseNotesEntry] with the given fields.
  const SdkReleaseNotesEntry({
    required this.version,
    required this.changes,
    required this.sections,
    required this.breaking,
    this.date,
  });

  /// Constructs an [SdkReleaseNotesEntry] from a parsed changelog map.
  factory SdkReleaseNotesEntry.fromJson(Map<String, Object?> json) => SdkReleaseNotesEntry(
    version: _optStr(json, 'version') ?? '',
    date: DateTime.tryParse(_optStr(json, 'date') ?? ''),
    changes: _strList(json, 'changes'),
    sections: _sectionsMap(json, 'sections'),
    breaking: (json['breaking'] as bool?) ?? false,
  );

  /// The version string for this release notes entry (e.g. `"3.14.0"`).
  final String version;

  /// The release date for this version, or `null` when the field is absent or unparseable.
  final DateTime? date;

  /// Flat list of change descriptions for this version across all sections.
  final List<String> changes;

  /// Categorized map of change descriptions keyed by section name.
  final Map<String, List<String>> sections;

  /// Whether this version contains breaking changes.
  final bool breaking;

  /// Returns a copy of this entry with the given fields replaced.
  SdkReleaseNotesEntry copyWith({
    String? version,
    DateTime? date,
    List<String>? changes,
    Map<String, List<String>>? sections,
    bool? breaking,
  }) => SdkReleaseNotesEntry(
    version: version ?? this.version,
    date: date ?? this.date,
    changes: changes ?? this.changes,
    sections: sections ?? this.sections,
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
    this.enclosedBy,
  });

  /// Constructs a [DartdocSymbol] from a single entry in `index.json`.
  ///
  /// The raw `kind` integer is mapped to a readable [type] string; any
  /// unrecognised value is kept as its decimal string representation.
  ///
  /// [enclosedBy] is populated from the raw `enclosedBy.name` only when the
  /// enclosing entity is a non-library container (a class, enum, mixin, …).
  /// Top-level symbols whose container is the library itself (kind `9`) —
  /// and symbols with no `enclosedBy` — carry a `null` [enclosedBy].
  factory DartdocSymbol.fromJson(Map<String, Object?> json) => DartdocSymbol(
    name: _optStr(json, 'name') ?? '',
    qualifiedName: _optStr(json, 'qualifiedName') ?? '',
    href: _optStr(json, 'href') ?? '',
    type: _kindToType((json['kind'] as int?) ?? -1),
    desc: _optStr(json, 'desc') ?? '',
    enclosedBy: _parseEnclosedBy(json['enclosedBy']),
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

  /// The name of the enclosing container for methods, constructors, accessors
  /// and other members (e.g. `"BrowserClient"`).
  ///
  /// `null` for top-level symbols — classes, enums, extensions, top-level
  /// functions, and library entries — whose container is the library itself.
  final String? enclosedBy;

  /// Returns a copy of this symbol with the given fields replaced.
  DartdocSymbol copyWith({
    String? name,
    String? qualifiedName,
    String? href,
    String? type,
    String? desc,
    String? enclosedBy,
  }) => DartdocSymbol(
    name: name ?? this.name,
    qualifiedName: qualifiedName ?? this.qualifiedName,
    href: href ?? this.href,
    type: type ?? this.type,
    desc: desc ?? this.desc,
    enclosedBy: enclosedBy ?? this.enclosedBy,
  );

  /// Extracts the enclosing container name from a raw `enclosedBy` entry.
  ///
  /// Returns `null` when the entry is absent, malformed, or refers to a
  /// library (kind `9`) — so that top-level symbols report no container.
  static String? _parseEnclosedBy(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    if ((raw['kind'] as int?) == 9) return null; // library container
    return _optStr(raw, 'name');
  }

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

// ─── OsvEvent ─────────────────────────────────────────────────────────────────

/// One OSV range event: a version boundary that toggles whether a version is
/// considered affected.
///
/// Exactly one field is expected to be non-null per event, mirroring the OSV
/// schema's `events` array shape. `introduced` may carry the literal `"0"`
/// sentinel meaning "affected since the beginning" rather than a parseable
/// semver string.
final class OsvEvent {
  /// Creates an [OsvEvent] with the given fields.
  const OsvEvent({this.introduced, this.fixed, this.lastAffected, this.limit});

  /// Constructs an [OsvEvent] from one entry of an OSV range's `events` array.
  factory OsvEvent.fromJson(Map<String, Object?> json) => OsvEvent(
    introduced: _optStr(json, 'introduced'),
    fixed: _optStr(json, 'fixed'),
    lastAffected: _optStr(json, 'last_affected'),
    limit: _optStr(json, 'limit'),
  );

  /// The version this range becomes affected from, inclusive. The literal
  /// `"0"` means "since the beginning" rather than a parseable semver string.
  final String? introduced;

  /// The version this range stops being affected from, inclusive
  /// (`version >= fixed` is unaffected).
  final String? fixed;

  /// The last version still affected, inclusive (`version > lastAffected` is
  /// unaffected).
  final String? lastAffected;

  /// An exclusive upper bound past which this range no longer applies.
  final String? limit;

  /// Returns a copy of this event with the given fields replaced.
  OsvEvent copyWith({String? introduced, String? fixed, String? lastAffected, String? limit}) =>
      OsvEvent(
        introduced: introduced ?? this.introduced,
        fixed: fixed ?? this.fixed,
        lastAffected: lastAffected ?? this.lastAffected,
        limit: limit ?? this.limit,
      );
}

// ─── OsvRange ─────────────────────────────────────────────────────────────────

/// One OSV affected range: an ordered list of [OsvEvent]s that together
/// describe which versions of a package a [SecurityAdvisory] affects.
final class OsvRange {
  /// Creates an [OsvRange] with the given [events].
  const OsvRange({required this.events});

  /// Constructs an [OsvRange] from one entry of an `affected[].ranges` array.
  factory OsvRange.fromJson(Map<String, Object?> json) => OsvRange(
    events: ((json['events'] as List<Object?>?) ?? const [])
        .whereType<Map<String, Object?>>()
        .map(OsvEvent.fromJson)
        .toList(),
  );

  /// The ordered events describing this range's affected/unaffected boundaries.
  final List<OsvEvent> events;

  /// Returns a copy of this range with [events] replaced.
  OsvRange copyWith({List<OsvEvent>? events}) => OsvRange(events: events ?? this.events);
}

// ─── SecurityAdvisory ──────────────────────────────────────────────────────────

/// A single OSV-format security advisory published against a package.
///
/// Sourced from `GET /api/packages/{name}/advisories`. [ranges] flattens
/// every `affected[].ranges` entry from the raw advisory — pub.dev's endpoint
/// already scopes advisories to the requested package, so no further
/// filtering by package name is needed. Evaluate [ranges] against a concrete
/// version with `osvRangesAffectVersion`.
final class SecurityAdvisory {
  /// Creates a [SecurityAdvisory] with the given fields.
  const SecurityAdvisory({
    required this.id,
    required this.aliases,
    required this.summary,
    required this.url,
    required this.ranges,
  });

  /// Constructs a [SecurityAdvisory] from one entry of the `advisories` array.
  ///
  /// [url] prefers `database_specific.pub_display_url` (the GitHub Advisories
  /// page pub.dev links to) and falls back to the advisory's OSV.dev page,
  /// which exists for every valid OSV id.
  factory SecurityAdvisory.fromJson(Map<String, Object?> json) {
    final id = _optStr(json, 'id') ?? '';
    final databaseSpecific = json['database_specific'] as Map<String, Object?>?;
    final pubDisplayUrl = databaseSpecific != null ? _optStr(databaseSpecific, 'pub_display_url') : null;

    final ranges = <OsvRange>[];
    for (final affected in ((json['affected'] as List<Object?>?) ?? const [])
        .whereType<Map<String, Object?>>()) {
      ranges.addAll(
        ((affected['ranges'] as List<Object?>?) ?? const [])
            .whereType<Map<String, Object?>>()
            .map(OsvRange.fromJson),
      );
    }

    return SecurityAdvisory(
      id: id,
      aliases: ((json['aliases'] as List<Object?>?) ?? const []).whereType<String>().toList(),
      summary: _optStr(json, 'summary') ?? '',
      url: pubDisplayUrl ?? 'https://osv.dev/$id',
      ranges: ranges,
    );
  }

  /// The advisory's primary id (e.g. `"GHSA-4rgh-jx4f-qfcq"`).
  final String id;

  /// Alternate ids for the same advisory (e.g. `["CVE-2020-35669"]`).
  final List<String> aliases;

  /// A short human-readable summary of the vulnerability.
  final String summary;

  /// A URL to the advisory's detail page.
  final String url;

  /// Every OSV affected range across the advisory's `affected` entries.
  final List<OsvRange> ranges;

  /// Returns a copy of this advisory with the given fields replaced.
  SecurityAdvisory copyWith({
    String? id,
    List<String>? aliases,
    String? summary,
    String? url,
    List<OsvRange>? ranges,
  }) => SecurityAdvisory(
    id: id ?? this.id,
    aliases: aliases ?? this.aliases,
    summary: summary ?? this.summary,
    url: url ?? this.url,
    ranges: ranges ?? this.ranges,
  );
}
