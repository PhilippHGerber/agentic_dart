/// On-disk LRU cache for package tarball archives.
library;

import 'dart:async';
import 'dart:io';

/// Default maximum combined size for cached tarballs: 500 MiB.
const int kDefaultTarballCacheMaxSizeBytes = 500 * 1024 * 1024;

final class _CachedTarballEntry {
  _CachedTarballEntry({
    required this.file,
    required this.sizeBytes,
    required this.lastAccess,
  });

  final File file;
  final int sizeBytes;
  final DateTime lastAccess;
}

/// LRU, size-capped cache for `.tar.gz` package archives.
///
/// Entries are keyed as `{name}@{version}.tar.gz`. LRU state is persisted by
/// updating file modification times on cache reads and writes.
final class TarballDiskCache {
  /// Creates a [TarballDiskCache] rooted at [directoryPath].
  TarballDiskCache({
    required String directoryPath,
    this.maxSizeBytes = kDefaultTarballCacheMaxSizeBytes,
    DateTime Function()? clock,
  }) : _directory = Directory(directoryPath),
       _clock = clock ?? DateTime.now {
    if (maxSizeBytes <= 0) {
      throw ArgumentError.value(
        maxSizeBytes,
        'maxSizeBytes',
        'must be greater than zero',
      );
    }
  }

  final Directory _directory;
  final DateTime Function() _clock;

  /// Upper bound for total cache size across all tarballs.
  final int maxSizeBytes;

  Future<void> _serial = Future<void>.value();

  /// Returns the cache root directory path.
  String get directoryPath => _directory.path;

  /// Reads cached bytes for `{name}@{version}`, or `null` on cache miss.
  Future<List<int>?> read(String name, String version) => _queue<List<int>?>(() async {
    _ensureDirectory();

    final file = _fileFor(name, version);
    if (!file.existsSync()) return null;

    try {
      final bytes = file.readAsBytesSync();
      _touch(file);
      return bytes;
    } on FileSystemException {
      return null;
    }
  });

  /// Stores [bytes] under `{name}@{version}` and evicts least-recently-used
  /// entries until total size is within [maxSizeBytes].
  Future<void> write(String name, String version, List<int> bytes) => _queue<void>(() async {
    _ensureDirectory();

    // If one tarball is larger than the entire cache budget, skip caching.
    if (bytes.length > maxSizeBytes) return;

    final file = _fileFor(name, version);
    final tempFile = File('${file.path}.tmp-${_clock().microsecondsSinceEpoch}');

    try {
      tempFile.writeAsBytesSync(bytes, flush: true);
      if (file.existsSync()) {
        file.deleteSync();
      }
      tempFile.renameSync(file.path);
      _touch(file);
      _evictToCap();
    } on FileSystemException {
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } on FileSystemException {
          // Best-effort cleanup.
        }
      }
    }
  });

  Future<T> _queue<T>(Future<T> Function() action) {
    final completer = Completer<T>();

    _serial = _serial.catchError((Object _) {}).then((_) async {
      try {
        completer.complete(await action());
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });

    return completer.future;
  }

  void _ensureDirectory() {
    if (_directory.existsSync()) return;
    _directory.createSync(recursive: true);
  }

  void _touch(File file) {
    try {
      file.setLastModifiedSync(_clock());
    } on FileSystemException {
      // Best-effort LRU metadata update.
    }
  }

  void _evictToCap() {
    final entries = _listEntries();
    var totalSize = entries.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);

    if (totalSize <= maxSizeBytes) return;

    entries.sort((a, b) => a.lastAccess.compareTo(b.lastAccess));
    for (final entry in entries) {
      try {
        entry.file.deleteSync();
      } on FileSystemException {
        continue;
      }
      totalSize -= entry.sizeBytes;
      if (totalSize <= maxSizeBytes) return;
    }
  }

  List<_CachedTarballEntry> _listEntries() {
    final entries = <_CachedTarballEntry>[];

    for (final entity in _directory.listSync(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.tar.gz')) continue;

      try {
        final stat = entity.statSync();
        if (stat.type != FileSystemEntityType.file) continue;
        entries.add(
          _CachedTarballEntry(
            file: entity,
            sizeBytes: stat.size,
            lastAccess: stat.modified,
          ),
        );
      } on FileSystemException {
        continue;
      }
    }

    return entries;
  }

  // Allows letters, digits, and underscores — excludes path separators.
  static final _kSafeName = RegExp(r'^[a-zA-Z0-9_]+$');

  // Allows semver characters (digits, letters, dots, hyphens, underscores,
  // plus signs) — excludes path separators.
  static final _kSafeVersion = RegExp(r'^[0-9a-zA-Z.+_-]+$');

  File _fileFor(String name, String version) {
    if (!_kSafeName.hasMatch(name)) {
      throw ArgumentError.value(
        name,
        'name',
        'must only contain letters, digits, and underscores',
      );
    }
    if (!_kSafeVersion.hasMatch(version)) {
      throw ArgumentError.value(
        version,
        'version',
        'must only contain letters, digits, dots, hyphens, underscores, and plus signs',
      );
    }
    final fileName = '$name@$version.tar.gz';
    return File(_joinPath(_directory.path, fileName));
  }

  static String _joinPath(String base, String child) {
    final separator = Platform.pathSeparator;
    if (base.endsWith(separator)) return '$base$child';
    return '$base$separator$child';
  }
}
