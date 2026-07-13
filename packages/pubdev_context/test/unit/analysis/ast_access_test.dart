/// Unit tests for [AstAccess].
library;

import 'dart:typed_data';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:pubdev_context/src/analysis/ast_access.dart';
import 'package:pubdev_context/src/cache/cache_registry.dart';
import 'package:pubdev_context/src/data/domain_error.dart';
import 'package:test/test.dart';

import '../../support/harness.dart';

// ─── Fixtures ─────────────────────────────────────────────────────────────────

/// A class exercising every member-lookup shape: a method, a named
/// constructor, the unnamed constructor, `operator ==`, a getter/setter pair
/// sharing a name, and a field.
const _widgetSource = '''
class Widget {
  final int id;

  Widget(this.id);
  Widget.named(this.id);

  int compute(int x) => x * 2 + id;

  @override
  bool operator ==(Object other) => other is Widget && other.id == id;

  int get value => id;
  set value(int next) {}
}
''';

const Map<String, String> _files = {
  'lib/src/widget.dart': _widgetSource,
  'README.md': '# foo',
};

// ─── Helpers ──────────────────────────────────────────────────────────────────

Uint8List _buildTarGz(Map<String, String> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile.string(entry.key, entry.value));
  }
  final tar = TarEncoder().encodeBytes(archive);
  return const GZipEncoder().encodeBytes(tar);
}

void _stubTarball(
  MockHttpClient mock,
  Map<String, String> files, {
  String name = 'foo',
  String version = '1.0.0',
}) {
  when(
    () => mock.send(
      any(
        that: predicate<http.BaseRequest>(
          (r) => r.url.toString().contains(
            '/api/packages/$name/versions/$version/archive.tar.gz',
          ),
        ),
      ),
    ),
  ).thenAnswer((_) async => http.StreamedResponse(Stream.value(_buildTarGz(files)), 200));
}

// ─── Tests ────────────────────────────────────────────────────────────────────

void main() {
  late TestStack stack;
  late MockHttpClient mockHttp;
  late CacheRegistry registry;

  AstAccess buildAccess() =>
      AstAccess(sourceFiles: registry.sourceFiles, ast: registry.ast);

  setUp(() {
    stack = TestStack();
    mockHttp = stack.http;
    registry = stack.caches;
  });

  tearDown(() => stack.close());

  // ─── fileText ─────────────────────────────────────────────────────────────

  group('fileText', () {
    test('returns the raw file content on a hit', () async {
      _stubTarball(mockHttp, _files);

      final result = await buildAccess().fileText('foo', '1.0.0', 'lib/src/widget.dart');

      expect(result, isA<PubDevSuccess<String>>());
      expect((result as PubDevSuccess<String>).value, equals(_widgetSource));
    });

    test('returns SOURCE_FILE_NOT_FOUND for a missing path', () async {
      _stubTarball(mockHttp, _files);

      final result = await buildAccess().fileText('foo', '1.0.0', 'lib/src/missing.dart');

      expect(result, isA<PubDevFailure<String>>());
      expect((result as PubDevFailure<String>).error.code, equals(DomainErrors.sourceFileNotFound));
    });

    test('suggests a filename match when one exists', () async {
      _stubTarball(mockHttp, {'lib/src/server/widget.dart': 'class Widget {}'});

      final result = await buildAccess().fileText('foo', '1.0.0', 'lib/widget.dart');

      expect(
        (result as PubDevFailure<String>).error.suggestion,
        contains('lib/src/server/widget.dart'),
      );
    });

    test('falls back to a generic suggestion when no filename matches', () async {
      _stubTarball(mockHttp, _files);

      final result = await buildAccess().fileText('foo', '1.0.0', 'lib/does_not_exist.dart');

      expect(
        (result as PubDevFailure<String>).error.suggestion,
        contains('list_package_source_files'),
      );
    });

    test('propagates PACKAGE_NOT_FOUND when the package is missing', () async {
      when(() => mockHttp.send(any())).thenAnswer(
        (_) async => http.StreamedResponse(Stream.value(<int>[]), 404),
      );

      final result = await buildAccess().fileText('missing', '1.0.0', 'lib/src/widget.dart');

      expect(
        (result as PubDevFailure<String>).error.code,
        equals(DomainErrors.packageNotFound),
      );
    });
  });

  // ─── unit ─────────────────────────────────────────────────────────────────

  group('unit', () {
    test('parses the file and exposes content/unit/lineInfo', () async {
      _stubTarball(mockHttp, _files);

      final result = await buildAccess().unit('foo', '1.0.0', 'lib/src/widget.dart');

      expect(result, isA<PubDevSuccess<ParseStringResult>>());
      final ast = (result as PubDevSuccess<ParseStringResult>).value;
      expect(ast.content, equals(_widgetSource));
      expect(ast.unit.declarations, hasLength(1));
    });

    test('propagates SOURCE_FILE_NOT_FOUND for a missing path', () async {
      _stubTarball(mockHttp, _files);

      final result = await buildAccess().unit('foo', '1.0.0', 'lib/src/missing.dart');

      expect(
        (result as PubDevFailure<ParseStringResult>).error.code,
        equals(DomainErrors.sourceFileNotFound),
      );
    });

    test('does not re-download the tarball across repeated calls', () async {
      _stubTarball(mockHttp, _files);
      final access = buildAccess();

      await access.unit('foo', '1.0.0', 'lib/src/widget.dart');
      await access.unit('foo', '1.0.0', 'lib/src/widget.dart');

      verify(
        () => mockHttp.send(
          any(
            that: predicate<http.BaseRequest>(
              (r) => r.url.toString().contains('/archive.tar.gz'),
            ),
          ),
        ),
      ).called(1);
    });
  });

  // ─── member ───────────────────────────────────────────────────────────────

  group('member', () {
    late CompilationUnit widgetUnit;

    setUp(() async {
      _stubTarball(mockHttp, _files);
      final result = await buildAccess().unit('foo', '1.0.0', 'lib/src/widget.dart');
      widgetUnit = (result as PubDevSuccess<ParseStringResult>).value.unit;
    });

    test('returns null when the class is not declared in the unit', () {
      final access = buildAccess();
      expect(access.member(widgetUnit, 'DoesNotExist', memberName: 'compute'), isNull);
    });

    test('returns every member when memberName is omitted', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget');
      expect(members, isNotNull);
      // field, two constructors, method, operator==, getter, setter.
      expect(members!.length, equals(7));
    });

    test('returns an empty list when the class is found but no member matches', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'doesNotExist');
      expect(members, isNotNull);
      expect(members, isEmpty);
    });

    test('finds a method by name', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'compute');
      expect(members, hasLength(1));
      expect(members!.single, isA<MethodDeclaration>());
    });

    test('finds a named constructor', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'named');
      expect(members, hasLength(1));
      final ctor = members!.single as ConstructorDeclaration;
      expect(ctor.name?.lexeme, equals('named'));
    });

    test('finds the unnamed constructor via "new"', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'new');
      expect(members, hasLength(1));
      final ctor = members!.single as ConstructorDeclaration;
      expect(ctor.name, isNull);
    });

    test('finds operator== via "=="', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: '==');
      expect(members, hasLength(1));
      expect((members!.single as MethodDeclaration).name.lexeme, equals('=='));
    });

    test('finds operator== via "operator =="', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'operator ==');
      expect(members, hasLength(1));
      expect((members!.single as MethodDeclaration).name.lexeme, equals('=='));
    });

    test('returns both accessors when a getter and setter share a name', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'value');
      expect(members, hasLength(2));
      expect(members!.every((m) => m is MethodDeclaration), isTrue);
    });

    test('finds a field by name', () {
      final access = buildAccess();
      final members = access.member(widgetUnit, 'Widget', memberName: 'id');
      expect(members, hasLength(1));
      expect(members!.single, isA<FieldDeclaration>());
    });
  });
}
