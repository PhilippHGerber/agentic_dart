/// On-disk persistence for the Update Check's cross-restart rate-limit state
/// (see `CONTEXT.md`'s **Update Check** glossary entry).
library;

import 'dart:convert';
import 'dart:io';

/// The Update Check's persisted outcome: when it last ran and which Latest
/// Stable Version it found for `dart_pubdev_mcp` itself.
///
/// [latestVersion] is always the raw pub.dev result, independent of whether it
/// was newer than the running server at the time — the newer-than comparison
/// is re-run against the *current* running version on every reuse, not
/// baked into the persisted state.
final class UpdateCheckState {
  /// Creates an [UpdateCheckState].
  const UpdateCheckState({required this.checkedAt, required this.latestVersion});

  /// When the check that produced [latestVersion] ran.
  final DateTime checkedAt;

  /// The Latest Stable Version pub.dev reported for `dart_pubdev_mcp` at
  /// [checkedAt].
  final String latestVersion;
}

/// Persists [UpdateCheckState] to a small JSON file inside the existing
/// Tarball Disk Cache directory — no second, uncoordinated cache location.
///
/// A missing, corrupted, or otherwise unreadable state file is treated
/// identically to "no persisted state": [read] returns `null` rather than
/// throwing, so a fresh Update Check always runs in that case.
final class UpdateCheckStateStore {
  /// Creates an [UpdateCheckStateStore] rooted at [directoryPath] — the same
  /// directory root [directoryPath] the tarball cache uses.
  UpdateCheckStateStore({required String directoryPath, String fileName = 'update-check.json'})
    : _file = File(_joinPath(directoryPath, fileName));

  final File _file;

  /// Reads the persisted [UpdateCheckState], or `null` when the file is
  /// missing, corrupted, or otherwise unreadable.
  Future<UpdateCheckState?> read() async {
    try {
      if (!_file.existsSync()) return null;
      final raw = _file.readAsStringSync();
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, Object?>) return null;

      final checkedAtRaw = decoded['checkedAt'];
      final latestVersion = decoded['latestVersion'];
      if (checkedAtRaw is! String || latestVersion is! String) return null;

      final checkedAt = DateTime.tryParse(checkedAtRaw);
      if (checkedAt == null) return null;

      return UpdateCheckState(checkedAt: checkedAt, latestVersion: latestVersion);
    } on Object {
      return null;
    }
  }

  /// Writes [state], creating the target directory if needed. Best-effort: a
  /// write failure is swallowed rather than thrown, matching the Update
  /// Check's overall "never break a tool call" failure policy.
  Future<void> write(UpdateCheckState state) async {
    final tempFile = File('${_file.path}.tmp-${DateTime.now().microsecondsSinceEpoch}');
    try {
      _file.parent.createSync(recursive: true);
      tempFile.writeAsStringSync(
        jsonEncode({
          'checkedAt': state.checkedAt.toIso8601String(),
          'latestVersion': state.latestVersion,
        }),
      );
      if (_file.existsSync()) {
        _file.deleteSync();
      }
      tempFile.renameSync(_file.path);
    } on Object {
      // Best-effort persistence — a write failure has no observable effect on
      // the session, matching the Update Check's failure-handling policy.
      // Clean up a partially-written temp file rather than leaving it behind.
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } on FileSystemException {
          // Best-effort cleanup.
        }
      }
    }
  }

  static String _joinPath(String base, String child) {
    final separator = Platform.pathSeparator;
    if (base.endsWith(separator)) return '$base$child';
    return '$base$separator$child';
  }
}
