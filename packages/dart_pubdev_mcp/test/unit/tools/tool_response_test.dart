/// Unit tests for [ToolResponse].
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';
import 'package:dart_pubdev_mcp/src/data/domain_error.dart';
import 'package:dart_pubdev_mcp/src/tools/tool_response.dart';
import 'package:test/test.dart';

String _text(CallToolResult result) => (result.content.single as TextContent).text;

void main() {
  group('ToolResponse.ok', () {
    test('is not an error', () {
      final result = ToolResponse.ok({'name': 'http'});
      expect(result.isError, isNull);
    });

    test('encodes the payload as a single TextContent block', () {
      final result = ToolResponse.ok({'name': 'http', 'version': '1.2.0'});
      expect(jsonDecode(_text(result)), equals({'name': 'http', 'version': '1.2.0'}));
    });

    test('omits resolvedVersion from the body when not supplied', () {
      final result = ToolResponse.ok({'name': 'http'});
      expect(jsonDecode(_text(result)), isNot(contains('resolvedVersion')));
    });

    test('inserts resolvedVersion as the first JSON key when supplied', () {
      final result = ToolResponse.ok({'name': 'http'}, resolvedVersion: '1.2.0');
      final decoded = jsonDecode(_text(result)) as Map<String, Object?>;
      expect(decoded.keys.first, equals('resolvedVersion'));
      expect(decoded, equals({'resolvedVersion': '1.2.0', 'name': 'http'}));
    });

    test('resolvedVersion precedes an existing key of the same family', () {
      final result = ToolResponse.ok(
        {'package': 'http', 'file': 'lib/http.dart'},
        resolvedVersion: '1.2.0',
      );
      final decoded = jsonDecode(_text(result)) as Map<String, Object?>;
      expect(decoded.keys.toList(), equals(['resolvedVersion', 'package', 'file']));
    });

    test('accepts a bare List payload for search_packages-style responses', () {
      final result = ToolResponse.ok([
        {'name': 'http'},
        {'name': 'dio'},
      ]);
      expect(
        jsonDecode(_text(result)),
        equals([
          {'name': 'http'},
          {'name': 'dio'},
        ]),
      );
    });
  });

  group('ToolResponse.error', () {
    const error = DomainError(
      code: DomainErrors.packageNotFound,
      message: 'Package not found.',
      suggestion: 'Verify the package name.',
    );

    test('sets isError to true', () {
      final result = ToolResponse.error(error);
      expect(result.isError, isTrue);
    });

    test('encodes the ADR-0002 nested error envelope', () {
      final result = ToolResponse.error(error);
      expect(jsonDecode(_text(result)), equals(error.toJson()));
    });
  });
}
