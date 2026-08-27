/// Conformance tests for every tool's declared `outputSchema`.
///
/// Each case is a golden sample shaped exactly like a real handler's success
/// payload (see the handler source for the authoritative shape), validated
/// against the matching `Tool.outputSchema` from `tool_definitions.dart`.
library;

import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart';
import 'package:test/test.dart';

import '../../support/schema_conformance.dart';

void main() {
  group('outputSchema conformance', () {
    test('search_packages', () {
      expectConformsToOutputSchema(searchPackagesTool, {
        'packages': [
          {
            'package': 'http',
            'version': '1.2.0',
            'description': 'A composable, multi-platform HTTP client.',
            'likes': 3000,
            'pubPoints': 160,
            'popularity': 100000,
            'verified': true,
            'sdks': ['dart', 'flutter'],
            'platforms': ['android', 'ios', 'web'],
            'topics': ['network', 'http'],
            'isFlutterFavorite': true,
            'daysSinceUpdate': 10,
            'activeMaintenance': true,
            'publisher': 'dart.dev',
            'license': 'BSD-3-Clause',
          },
        ],
      });
    });

    test('search_packages (optional fields omitted)', () {
      expectConformsToOutputSchema(searchPackagesTool, {
        'packages': [
          {
            'package': 'unverified_pkg',
            'version': '0.1.0',
            'description': 'An unverified package.',
            'likes': 0,
            'pubPoints': 0,
            'popularity': 0,
            'verified': false,
            'sdks': <String>[],
            'platforms': <String>[],
            'topics': <String>[],
            'isFlutterFavorite': false,
            'daysSinceUpdate': 200,
            'activeMaintenance': false,
          },
        ],
      });
    });

    test('search_packages (zero results)', () {
      expectConformsToOutputSchema(searchPackagesTool, {
        'packages': <Object?>[],
      });
    });

    test('get_package', () {
      expectConformsToOutputSchema(getPackageTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'version': '1.2.0',
        'description': 'A composable, multi-platform HTTP client.',
        'verified': true,
        'publishedAt': '2024-01-01T00:00:00.000Z',
        'activeMaintenance': true,
        'likes': 3000,
        'pubPoints': 160,
        'popularity': 100000,
        'sdkConstraints': {'dart': '>=3.0.0 <4.0.0', 'flutter': '>=3.0.0'},
        'platforms': ['android', 'ios', 'web'],
        'topics': ['network'],
        'isFlutterFavorite': true,
        'dependencies': {'async': '^2.0.0'},
        'devDependencies': {'test': '^1.0.0'},
        'versionsRecent': ['1.2.0', '1.1.0'],
        'publisher': 'dart.dev',
        'license': 'BSD-3-Clause',
        'readmeExcerpt': 'A composable...',
        'repository': 'https://github.com/dart-lang/http',
        'advisories': {
          'count': 1,
          'ids': ['GHSA-4rgh-jx4f-qfcq'],
          'affectsResolvedVersion': false,
        },
      });
    });

    test('get_package (optional fields omitted)', () {
      expectConformsToOutputSchema(getPackageTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'version': '1.2.0',
        'description': 'A composable, multi-platform HTTP client.',
        'verified': false,
        'activeMaintenance': false,
        'likes': 0,
        'pubPoints': 0,
        'popularity': 0,
        'sdkConstraints': {'dart': '>=3.0.0 <4.0.0'},
        'platforms': <String>[],
        'topics': <String>[],
        'isFlutterFavorite': false,
        'dependencies': <String, Object?>{},
        'devDependencies': <String, Object?>{},
        'versionsRecent': <String>[],
      });
    });

    test('get_changelog', () {
      expectConformsToOutputSchema(getChangelogTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'entries': [
          {
            'version': '1.2.0',
            'date': '2024-01-01T00:00:00.000Z',
            'changes': ['Added foo', 'Fixed bar'],
            'rawText': '- Added foo\n- Fixed bar',
            'breaking': false,
          },
          {
            'version': '1.1.0',
            'changes': ['Initial release'],
            'rawText': '- Initial release',
            'breaking': true,
          },
        ],
      });
    });

    test('get_security_advisories', () {
      expectConformsToOutputSchema(getSecurityAdvisoriesTool, {
        'resolvedVersion': '0.12.0',
        'package': 'http',
        'affecting': [
          {
            'id': 'GHSA-4rgh-jx4f-qfcq',
            'aliases': ['CVE-2020-35669'],
            'summary': 'http before 0.13.3 vulnerable to header injection',
            'url': 'https://github.com/advisories/GHSA-4rgh-jx4f-qfcq',
            'affectedRanges': [
              {
                'events': [
                  {'introduced': '0'},
                  {'fixed': '0.13.3'},
                ],
              },
            ],
          },
        ],
        'other': <Object?>[],
      });
    });

    test('get_security_advisories (zero advisories)', () {
      expectConformsToOutputSchema(getSecurityAdvisoriesTool, {
        'resolvedVersion': '1.6.0',
        'package': 'http',
        'affecting': <Object?>[],
        'other': <Object?>[],
      });
    });

    test('browse_api_symbols', () {
      expectConformsToOutputSchema(browseApiSymbolsTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'symbols': [
          {
            'name': 'Client',
            'qualifiedName': 'http.Client',
            'kind': 'class',
            'library': 'package:http/http.dart',
            'enclosedBy': null,
            'description': 'An HTTP client.',
            'href': 'http/Client-class.html',
          },
          {
            'name': 'get',
            'qualifiedName': 'http.get',
            'kind': 'function',
            'library': 'package:http/http.dart',
            'enclosedBy': null,
            'description': '',
            'href': 'http/get.html',
          },
        ],
      });
    });

    test('find_symbols', () {
      expectConformsToOutputSchema(findSymbolsTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'hasMore': true,
        'symbols': [
          {
            'name': 'send',
            'qualifiedName': 'http.Client.send',
            'kind': 'method',
            'library': 'package:http/http.dart',
            'enclosedBy': 'Client',
            'description': 'Sends an HTTP request.',
            'href': 'http/Client/send.html',
          },
          {
            'name': 'get',
            'qualifiedName': 'http.get',
            'kind': 'function',
            'library': 'package:http/http.dart',
            'enclosedBy': null,
            'description': '',
            'href': 'http/get.html',
          },
        ],
      });
    });

    test('get_symbol_documentation', () {
      expectConformsToOutputSchema(getSymbolDocumentationTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'symbol': 'Client',
        'documentation': 'class Client\n\nAn HTTP client...',
      });
    });

    test('get_source_slice (line-range mode)', () {
      expectConformsToOutputSchema(getSourceSliceTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'path': 'lib/http.dart',
        'mode': 'line-range',
        'lineStart': 1,
        'lineEnd': 40,
        'truncated': false,
        'content': 'library http;\n',
      });
    });

    test('get_source_slice (symbol mode)', () {
      expectConformsToOutputSchema(getSourceSliceTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'path': 'lib/http.dart',
        'mode': 'symbol',
        'symbol': 'Client',
        'lineStart': 40,
        'lineEnd': 120,
        'truncated': true,
        'content': 'class Client {\n  // ... 78 lines omitted ...\n}',
      });
    });

    test('get_sdk_source_slice (line-range mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'path': 'list.dart',
        'mode': 'line-range',
        'lineStart': 1,
        'lineEnd': 40,
        'truncated': false,
        'content': 'class List<E> {\n',
      });
    });

    test('get_sdk_source_slice (flutter, line-range mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'package': 'flutter',
        'path': 'src/widgets/framework.dart',
        'mode': 'line-range',
        'lineStart': 1,
        'lineEnd': 40,
        'truncated': false,
        'content': 'abstract class Widget {\n',
      });
    });

    test('get_sdk_source_slice (symbol mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'path': 'list.dart',
        'mode': 'symbol',
        'symbol': 'MyList',
        'lineStart': 1,
        'lineEnd': 40,
        'truncated': true,
        'content': 'class MyList {\n  // ... 38 lines omitted ...\n}',
      });
    });

    test('get_sdk_source_slice (flutter, symbol mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'package': 'flutter',
        'path': 'src/widgets/framework.dart',
        'mode': 'symbol',
        'symbol': 'State.setState',
        'lineStart': 40,
        'lineEnd': 60,
        'truncated': false,
        'content': 'void setState(VoidCallback fn) {\n  fn();\n}',
      });
    });

    test('list_sdk_source_files (dart, filtered)', () {
      expectConformsToOutputSchema(listSdkSourceFilesTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'paths': ['lib/core/list.dart', 'lib/core/map.dart'],
      });
    });

    test('list_sdk_source_files (flutter, unfiltered)', () {
      expectConformsToOutputSchema(listSdkSourceFilesTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'paths': ['packages/flutter/lib/src/widgets/framework.dart'],
      });
    });

    test('list_package_source_files', () {
      expectConformsToOutputSchema(listPackageSourceFilesTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'paths': ['lib/http.dart', 'lib/src/client.dart'],
      });
    });

    test('grep_package_source', () {
      expectConformsToOutputSchema(grepPackageSourceTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'pattern': 'isEmpty',
        'hasMore': false,
        'matches': [
          {
            'path': 'lib/src/client.dart',
            'line': 42,
            'matchedLine': '  if (uri.path.isEmpty) {',
            'contextBefore': ['class Client {'],
            'contextAfter': ['    throw ArgumentError();'],
          },
        ],
      });
    });

    test('grep_sdk_source (dart)', () {
      expectConformsToOutputSchema(grepSdkSourceTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'pattern': 'isEmpty',
        'hasMore': false,
        'matches': [
          {
            'path': 'lib/core/list.dart',
            'line': 42,
            'matchedLine': '  bool get isEmpty => length == 0;',
            'contextBefore': ['class List<E> {'],
            'contextAfter': ['  bool get isNotEmpty => !isEmpty;'],
          },
        ],
      });
    });

    test('grep_sdk_source (flutter)', () {
      expectConformsToOutputSchema(grepSdkSourceTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'package': 'flutter',
        'pattern': 'RenderParagraph',
        'hasMore': false,
        'matches': [
          {
            'path': 'packages/flutter/lib/src/rendering/paragraph.dart',
            'line': 42,
            'matchedLine': 'class RenderParagraph extends RenderBox {',
            'contextBefore': <String>[],
            'contextAfter': <String>[],
          },
        ],
      });
    });

    test('get_throw_statements', () {
      expectConformsToOutputSchema(getThrowStatementsTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'throws': [
          {
            'path': 'lib/src/client.dart',
            'line': 42,
            'symbol': 'Client.send',
            'thrownType': 'ClientException',
            'context': 'if (closed) {\n  throw ClientException("closed");\n}',
          },
          {
            'path': 'lib/src/utils.dart',
            'line': 15,
            'symbol': 'parseHeader',
            'thrownType': 'rethrow',
            'context': 'rethrow;',
          },
        ],
      });
    });

    test('get_sdk_throw_statements (dart)', () {
      expectConformsToOutputSchema(getSdkThrowStatementsTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'throws': [
          {
            'path': 'lib/core/list.dart',
            'line': 42,
            'symbol': 'MyList.add',
            'thrownType': 'RangeError',
            'context': 'if (full) {\n  throw RangeError("full");\n}',
          },
        ],
      });
    });

    test('get_sdk_throw_statements (flutter, top-level function)', () {
      expectConformsToOutputSchema(getSdkThrowStatementsTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'package': 'flutter',
        'throws': [
          {
            'path': 'packages/flutter/lib/src/widgets/framework.dart',
            'line': 42,
            'symbol': 'debugChecksAreDisabled',
            'thrownType': 'rethrow',
            'context': 'rethrow;',
          },
        ],
      });
    });

    test('compare_packages', () {
      expectConformsToOutputSchema(comparePackagesTool, {
        'packages': ['http', 'dio'],
        'errors': {'dio': 'PACKAGE_NOT_FOUND'},
        'matrix': {
          'likes': {'http': 3000},
          'license': {'http': null},
          'platforms': {
            'http': ['android', 'ios'],
          },
          'advisories': {'http': 1},
        },
      });
    });

    test('list_package_versions', () {
      expectConformsToOutputSchema(listPackageVersionsTool, {
        'package': 'http',
        'stable': [
          {'version': '1.2.0', 'publishedAt': '2024-01-01T00:00:00.000Z'},
        ],
        'prerelease': [
          {'version': '1.3.0-beta'},
        ],
        'retracted': <Object?>[],
      });
    });

    test('get_api_diff', () {
      expectConformsToOutputSchema(getApiDiffTool, {
        'package': 'http',
        'fromVersion': '0.13.0',
        'toVersion': '1.2.0',
        'added': {
          'libraries': <String>[],
          'classes': ['http.ClientException'],
          'methods': <String>[],
          'fields': <String>[],
        },
        'removed': {
          'libraries': <String>[],
          'classes': <String>[],
          'methods': ['http.Client.close'],
          'fields': <String>[],
        },
      });
    });

    test('get_sdk_release_notes', () {
      expectConformsToOutputSchema(getSdkReleaseNotesTool, {
        'resolvedVersion': '3.14.0',
        'sdk': 'dart',
        'entries': [
          {
            'version': '3.14.0',
            'date': '2025-01-15T00:00:00.000Z',
            'changes': [
              'dart:ffi: Added NativeFinalizer.callback support.',
              "Formatter: Don't crash.",
            ],
            'sections': {
              'Libraries': [
                'dart:ffi: Added NativeFinalizer.callback support.',
              ],
              'Tools': [
                "Formatter: Don't crash.",
              ],
            },
            'breaking': false,
          },
        ],
      });
    });
  });
}
