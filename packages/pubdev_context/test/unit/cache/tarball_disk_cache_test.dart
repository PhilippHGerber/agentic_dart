/// Unit tests for [TarballDiskCache].
library;

import 'dart:io';

import 'package:pubdev_context/src/cache/tarball_disk_cache.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('pubdev_context_tar_cache_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('TarballDiskCache.read/write', () {
    test('stores bytes on write and returns them on read', () async {
      final cache = TarballDiskCache(directoryPath: tempDir.path);
      final bytes = List<int>.generate(128, (i) => i % 255);

      await cache.write('http', '1.2.0', bytes);
      final readBack = await cache.read('http', '1.2.0');

      expect(readBack, isNotNull);
      expect(readBack, equals(bytes));
    });

    test('uses {name}@{version}.tar.gz file naming', () async {
      final cache = TarballDiskCache(directoryPath: tempDir.path);

      await cache.write('http', '1.2.0', [1, 2, 3]);

      final file = File('${tempDir.path}${Platform.pathSeparator}http@1.2.0.tar.gz');
      expect(file.existsSync(), isTrue);
      expect(await cache.read('http', '1.2.0'), equals([1, 2, 3]));
    });
  });

  group('TarballDiskCache LRU eviction', () {
    test('evicts least recently used entries when total size exceeds cap', () async {
      var fakeNow = DateTime.utc(2026);
      DateTime fakeClock() => fakeNow;

      final cache = TarballDiskCache(
        directoryPath: tempDir.path,
        maxSizeBytes: 11,
        clock: fakeClock,
      );

      await cache.write('a', '1.0.0', [1, 1, 1, 1]);
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      await cache.write('b', '1.0.0', [2, 2, 2, 2]);
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      await cache.read('a', '1.0.0');
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      await cache.write('c', '1.0.0', [3, 3, 3, 3]);

      expect(await cache.read('a', '1.0.0'), isNotNull);
      expect(await cache.read('b', '1.0.0'), isNull);
      expect(await cache.read('c', '1.0.0'), isNotNull);
    });
  });

  group('TarballDiskCache max size guard', () {
    test('does not cache an item larger than maxSizeBytes', () async {
      final cache = TarballDiskCache(
        directoryPath: tempDir.path,
        maxSizeBytes: 4,
      );

      await cache.write('big', '1.0.0', [1, 2, 3, 4, 5]);

      final file = File('${tempDir.path}${Platform.pathSeparator}big@1.0.0.tar.gz');
      expect(file.existsSync(), isFalse);
      expect(await cache.read('big', '1.0.0'), isNull);
    });
  });

  group('TarballDiskCache path validation', () {
    test('read throws ArgumentError when name contains a path separator', () {
      final cache = TarballDiskCache(directoryPath: tempDir.path);
      expect(
        () => cache.read('../etc', '1.0.0'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('write throws ArgumentError when version contains a path separator', () {
      final cache = TarballDiskCache(directoryPath: tempDir.path);
      expect(
        () => cache.write('foo', '../evil', [1, 2, 3]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('write throws ArgumentError when name contains a forward slash', () {
      final cache = TarballDiskCache(directoryPath: tempDir.path);
      expect(
        () => cache.write('a/b', '1.0.0', [1, 2, 3]),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
