/// Conformance tests for every tool's declared `outputSchema`.
///
/// Each case is a golden sample shaped exactly like a real handler's success
/// payload (see the handler source for the authoritative shape), validated
/// against the matching `Tool.outputSchema` from `tool_definitions.dart`.
/// `search_packages` is intentionally absent — see its doc comment in
/// `tool_definitions.dart` for why it declares no `outputSchema`.
library;

import 'package:dart_pubdev_mcp/src/tools/tool_definitions.dart';
import 'package:test/test.dart';

import '../../support/schema_conformance.dart';

void main() {
  group('outputSchema conformance', () {
    test('get_package', () {
      expectConformsToOutputSchema(getPackageTool, {
        'resolvedVersion': '1.2.0',
        'name': 'http',
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
      });
    });

    test('get_package (optional fields omitted)', () {
      expectConformsToOutputSchema(getPackageTool, {
        'resolvedVersion': '1.2.0',
        'name': 'http',
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
        'entries': [
          {
            'version': '1.2.0',
            'date': '2024-01-01T00:00:00.000Z',
            'changes': '- Added foo\n- Fixed bar',
            'breaking': false,
          },
          {'version': '1.1.0', 'changes': '- Initial release', 'breaking': true},
        ],
      });
    });

    test('browse_api_symbols', () {
      expectConformsToOutputSchema(browseApiSymbolsTool, {
        'resolvedVersion': '1.2.0',
        'symbols': [
          {
            'name': 'Client',
            'qualifiedName': 'http.Client',
            'href': 'http/Client-class.html',
            'type': 'class',
            'desc': 'An HTTP client.',
          },
          {
            'name': 'get',
            'qualifiedName': 'http.get',
            'href': 'http/get.html',
            'type': 'function',
          },
        ],
      });
    });

    test('find_symbols', () {
      expectConformsToOutputSchema(findSymbolsTool, {
        'resolvedVersion': '1.2.0',
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
        'documentation': 'class Client\n\nAn HTTP client...',
      });
    });

    test('get_source_slice (line-range mode)', () {
      expectConformsToOutputSchema(getSourceSliceTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'file': 'lib/http.dart',
        'mode': 'line-range',
        'lineStart': 1,
        'effectiveLineEnd': 40,
        'truncated': false,
        'content': 'library http;\n',
      });
    });

    test('get_source_slice (symbol mode)', () {
      expectConformsToOutputSchema(getSourceSliceTool, {
        'resolvedVersion': '1.2.0',
        'package': 'http',
        'file': 'lib/http.dart',
        'mode': 'symbol',
        'symbolName': 'Client',
        'lineStart': 40,
        'effectiveLineEnd': 120,
        'truncated': true,
        'content': 'class Client {\n  // ... 78 lines omitted ...\n}',
      });
    });

    test('get_sdk_source_slice (line-range mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'file': 'list.dart',
        'mode': 'line-range',
        'lineStart': 1,
        'effectiveLineEnd': 40,
        'truncated': false,
        'content': 'class List<E> {\n',
      });
    });

    test('get_sdk_source_slice (flutter, line-range mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'package': 'flutter',
        'file': 'src/widgets/framework.dart',
        'mode': 'line-range',
        'lineStart': 1,
        'effectiveLineEnd': 40,
        'truncated': false,
        'content': 'abstract class Widget {\n',
      });
    });

    test('get_sdk_source_slice (symbol mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'file': 'list.dart',
        'mode': 'symbol',
        'symbolName': 'MyList',
        'lineStart': 1,
        'effectiveLineEnd': 40,
        'truncated': true,
        'content': 'class MyList {\n  // ... 38 lines omitted ...\n}',
      });
    });

    test('get_sdk_source_slice (flutter, symbol mode)', () {
      expectConformsToOutputSchema(getSdkSourceSliceTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'package': 'flutter',
        'file': 'src/widgets/framework.dart',
        'mode': 'symbol',
        'symbolName': 'State.setState',
        'lineStart': 40,
        'effectiveLineEnd': 60,
        'truncated': false,
        'content': 'void setState(VoidCallback fn) {\n  fn();\n}',
      });
    });

    test('list_sdk_source_files (dart, filtered)', () {
      expectConformsToOutputSchema(listSdkSourceFilesTool, {
        'resolvedVersion': '3.12.2',
        'sdk': 'dart',
        'library': 'core',
        'files': ['lib/core/list.dart', 'lib/core/map.dart'],
      });
    });

    test('list_sdk_source_files (flutter, unfiltered)', () {
      expectConformsToOutputSchema(listSdkSourceFilesTool, {
        'resolvedVersion': '3.35.1',
        'sdk': 'flutter',
        'files': ['packages/flutter/lib/src/widgets/framework.dart'],
      });
    });

    test('list_package_source_files', () {
      expectConformsToOutputSchema(listPackageSourceFilesTool, {
        'resolvedVersion': '1.2.0',
        'name': 'http',
        'files': ['lib/http.dart', 'lib/src/client.dart'],
      });
    });

    test('get_throw_statements', () {
      expectConformsToOutputSchema(getThrowStatementsTool, {
        'resolvedVersion': '1.2.0',
        'throws': [
          {
            'file': 'lib/src/client.dart',
            'class': 'Client',
            'method': 'send',
            'thrown_type': 'ClientException',
            'context': 'if (closed) {\n  throw ClientException("closed");\n}',
          },
          {
            'file': 'lib/src/utils.dart',
            'function': 'parseHeader',
            'thrown_type': 'rethrow',
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
            'file': 'lib/core/list.dart',
            'class': 'MyList',
            'method': 'add',
            'thrown_type': 'RangeError',
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
            'file': 'packages/flutter/lib/src/widgets/framework.dart',
            'function': 'debugChecksAreDisabled',
            'thrown_type': 'rethrow',
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
  });
}
