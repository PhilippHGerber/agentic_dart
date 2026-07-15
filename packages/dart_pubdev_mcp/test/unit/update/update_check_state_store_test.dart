/// Unit tests for [UpdateCheckStateStore].
library;

import 'dart:io';

import 'package:dart_pubdev_mcp/src/update/update_check_state_store.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dart_pubdev_mcp_update_check_state_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('UpdateCheckStateStore.read/write', () {
    test('returns null when no state file has been written yet', () async {
      final store = UpdateCheckStateStore(directoryPath: tempDir.path);

      expect(await store.read(), isNull);
    });

    test('round-trips a written state', () async {
      final store = UpdateCheckStateStore(directoryPath: tempDir.path);
      final checkedAt = DateTime.utc(2026, 7, 15, 12);

      await store.write(UpdateCheckState(checkedAt: checkedAt, latestVersion: '1.2.3'));
      final state = await store.read();

      expect(state, isA<UpdateCheckState>());
      expect(state?.checkedAt, equals(checkedAt));
      expect(state?.latestVersion, equals('1.2.3'));
    });

    test('a later write overwrites an earlier one', () async {
      final store = UpdateCheckStateStore(directoryPath: tempDir.path);

      await store.write(
        UpdateCheckState(checkedAt: DateTime.utc(2026, 7), latestVersion: '1.0.0'),
      );
      await store.write(
        UpdateCheckState(checkedAt: DateTime.utc(2026, 7, 15), latestVersion: '2.0.0'),
      );
      final state = await store.read();

      expect(state?.checkedAt, equals(DateTime.utc(2026, 7, 15)));
      expect(state?.latestVersion, equals('2.0.0'));
    });

    test('creates the target directory on write when it does not exist yet', () async {
      final nested = '${tempDir.path}${Platform.pathSeparator}nested';
      final store = UpdateCheckStateStore(directoryPath: nested);

      await store.write(
        UpdateCheckState(checkedAt: DateTime.utc(2026, 7, 15), latestVersion: '1.2.3'),
      );

      expect(await store.read(), isNotNull);
    });

    test('treats a corrupted (non-JSON) state file as missing', () async {
      final store = UpdateCheckStateStore(directoryPath: tempDir.path);
      File(
        '${tempDir.path}${Platform.pathSeparator}update-check.json',
      ).writeAsStringSync('not json at all {{{');

      expect(await store.read(), isNull);
    });

    test('treats a state file missing required fields as missing', () async {
      final store = UpdateCheckStateStore(directoryPath: tempDir.path);
      File(
        '${tempDir.path}${Platform.pathSeparator}update-check.json',
      ).writeAsStringSync('{"checkedAt": "2026-07-15T00:00:00.000Z"}');

      expect(await store.read(), isNull);
    });

    test('treats a state file with an unparseable timestamp as missing', () async {
      final store = UpdateCheckStateStore(directoryPath: tempDir.path);
      File('${tempDir.path}${Platform.pathSeparator}update-check.json').writeAsStringSync(
        '{"checkedAt": "not-a-date", "latestVersion": "1.2.3"}',
      );

      expect(await store.read(), isNull);
    });
  });
}
