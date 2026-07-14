/// Shared domain-specific `MockHttpClient` stub builders for the three
/// pub.dev endpoints most handler tests need: package info (version
/// resolution), a dartdoc `index.json`, and a version tarball.
///
/// Kept separate from `harness.dart`, which stays free of response-decoding
/// and domain-shaped JSON/tarball construction — this file owns that.
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart' show predicate;

import 'harness.dart';

/// Stubs `GET /api/packages/{packageName}` so
/// `PubDevClient.resolveLatestStable` returns [version]. A non-200
/// [statusCode] serves an empty error body instead, so version resolution
/// fails with `package_not_found`.
void stubPackageInfo(
  MockHttpClient mock, {
  String packageName = 'http',
  String version = '1.6.0',
  int statusCode = 200,
}) {
  if (statusCode != 200) {
    when(
      () => mock.get(
        any(
          that: predicate<Uri>(
            (u) =>
                u.toString().contains('/api/packages/$packageName') &&
                !u.toString().contains('/score') &&
                !u.toString().contains('/versions/') &&
                !u.toString().contains('/archive'),
          ),
        ),
        headers: any(named: 'headers'),
      ),
    ).thenAnswer((_) async => http.Response('', statusCode));
    return;
  }
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) =>
              u.toString().contains('/api/packages/$packageName') &&
              !u.toString().contains('/score') &&
              !u.toString().contains('/versions/') &&
              !u.toString().contains('/archive'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => ok('{"versions":[{"version":"$version"}],"latest":{"version":"$version"}}'),
  );
}

/// Stubs `GET /documentation/{packageName}/{version}/index.json`. [body]
/// defaults to the `index_json.json` fixture; a non-200 [statusCode] serves a
/// plain error body instead.
void stubIndexJson(
  MockHttpClient mock, {
  int statusCode = 200,
  String packageName = 'http',
  String version = '1.6.0',
  String? body,
}) {
  when(
    () => mock.get(
      any(
        that: predicate<Uri>(
          (u) => u.toString().contains('/documentation/$packageName/$version/index.json'),
        ),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200
        ? ok(body ?? readFixture('index_json.json'))
        : http.Response('Not Found', statusCode),
  );
}

/// Builds an in-memory gzipped tarball from [files] (archive path → content).
Uint8List buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return const GZipEncoder().encodeBytes(tar);
}

/// Stubs the version-tarball endpoint (`send`, not `get`) with a gzip archive
/// built from [files]. A non-200 [statusCode] returns an empty streamed body.
void stubTarball(
  MockHttpClient mock,
  Map<String, String> files, {
  String packageName = 'foo',
  String version = '1.0.0',
  int statusCode = 200,
}) {
  when(
    () => mock.send(
      any(
        that: predicate<http.BaseRequest>(
          (r) => r.url.toString().contains(
            '/api/packages/$packageName/versions/$version/archive.tar.gz',
          ),
        ),
      ),
    ),
  ).thenAnswer(
    (_) async => statusCode == 200
        ? http.StreamedResponse(Stream.value(buildTarGz(files)), 200)
        : http.StreamedResponse(const Stream.empty(), statusCode),
  );
}
