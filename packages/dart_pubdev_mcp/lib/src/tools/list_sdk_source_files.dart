/// Handler for the `list_sdk_source_files` MCP tool.
///
/// Returns the list of file paths available in a Dart or Flutter SDK source
/// tree, mirroring `list_package_source_files` for pub.dev packages. Shares
/// the `sdkSourceFiles`/`sdkAst`-backed `AstAccess` facade with
/// `get_sdk_source_slice`, so once a given SDK ref's tarball is warm, listing
/// is free.
library;

import 'dart:io' show Platform;

import 'package:dart_mcp/server.dart';

import '../analysis/ast_access.dart';
import '../data/domain_error.dart';
import '../data/sdk_client.dart';
import 'path_filters.dart';
import 'tool_response.dart';

/// Handles calls to the `list_sdk_source_files` MCP tool.
final class ListSdkSourceFilesHandler {
  /// Creates a [ListSdkSourceFilesHandler].
  ///
  /// [astAccess] resolves SDK source-file maps — pass the same instance
  /// `get_sdk_source_slice` uses (wired over `CacheRegistry.sdkSourceFiles`/
  /// `sdkAst`) so a warm SDK tarball serves both tools. [platformVersion]
  /// overrides `Platform.version` for testing (Dart version auto-detection);
  /// [flutterEnvironment] overrides `Platform.environment` for testing
  /// (Flutter version auto-detection). Production callers omit both.
  ListSdkSourceFilesHandler({
    required AstAccess astAccess,
    required void Function(LoggingLevel, Object) log,
    String Function()? platformVersion,
    Map<String, String>? flutterEnvironment,
  }) : _astAccess = astAccess,
       _log = log,
       _platformVersion = platformVersion ?? (() => Platform.version),
       _flutterEnvironment = flutterEnvironment;

  final AstAccess _astAccess;
  final void Function(LoggingLevel, Object) _log;
  final String Function() _platformVersion;
  final Map<String, String>? _flutterEnvironment;

  /// Handles a [CallToolRequest] for `list_sdk_source_files`.
  Future<CallToolResult> call(CallToolRequest request) async {
    final args = request.arguments ?? const {};
    final sdk = (args['sdk'] as String?) ?? '';
    final suppliedVersion = args['version'] as String?;

    return switch (sdk) {
      'dart' => _handleDart(args, suppliedVersion),
      'flutter' => _handleFlutter(args, suppliedVersion),
      _ => ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message: 'sdk must be "dart" or "flutter".',
          suggestion: 'Pass sdk: "dart" or sdk: "flutter".',
        ),
      ),
    };
  }

  Future<CallToolResult> _handleDart(
    Map<String, Object?> args,
    String? suppliedVersion,
  ) async {
    final rawLibrary = args['library'] as String?;
    final library = (rawLibrary == null || rawLibrary.isEmpty) ? null : rawLibrary;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;
    if (library != null && !_isValidSegment(library)) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'The `library` parameter must be a single path segment '
              '(e.g. "core", "async", "io") — no "/" or ".." characters.',
          suggestion:
              'Pass the dart: library name, e.g. "core" for dart:core, '
              'or omit it to list every file.',
        ),
      );
    }

    final ref = suppliedVersion ?? resolveDartSdkRef(platformVersion: _platformVersion);

    _log(
      LoggingLevel.info,
      'list_sdk_source_files: sdk=dart ref=$ref${library != null ? ' library=$library' : ''}'
      '${rawDirectory != null ? ' directory=$rawDirectory' : ''}'
      '${fileExtension != null ? ' ext=$fileExtension' : ''}',
    );

    switch (await _astAccess.sourceFiles('dart_sdk', ref)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _ok(
          resolvedVersion: ref,
          sdk: 'dart',
          library: library,
          files: value,
          prefix: library == null ? null : 'lib/$library/',
          rawDirectory: rawDirectory,
          fileExtension: fileExtension,
        );
    }
  }

  Future<CallToolResult> _handleFlutter(
    Map<String, Object?> args,
    String? suppliedVersion,
  ) async {
    final rawPackage = args['package'] as String?;
    final package = (rawPackage == null || rawPackage.isEmpty) ? null : rawPackage;
    final rawDirectory = args['directory'] as String?;
    final fileExtension = args['fileExtension'] as String?;
    if (package != null && !_isValidSegment(package)) {
      return ToolResponse.error(
        const DomainError(
          code: DomainErrors.invalidArgument,
          message:
              'The `package` parameter must be a single path segment '
              '(e.g. "flutter", "flutter_test") — no "/" or ".." characters.',
          suggestion:
              'Pass the Flutter package name, e.g. "flutter", '
              'or omit it to list every file.',
        ),
      );
    }

    final String ref;
    if (suppliedVersion != null) {
      ref = suppliedVersion;
    } else {
      final detected = resolveFlutterSdkRef(environment: _flutterEnvironment);
      if (detected == null) {
        return ToolResponse.error(
          const DomainError(
            code: DomainErrors.sdkNotDetected,
            message: 'No local Flutter install was found via FLUTTER_ROOT or PATH.',
            suggestion:
                'If you have shell access, run `flutter --version --machine` and pass its '
                '`frameworkVersion` value as `version`; otherwise ask the user for their '
                'Flutter version. Setting FLUTTER_ROOT or adding flutter to PATH also works '
                "if you control this process's environment.",
            details: {'sdk': 'flutter'},
          ),
        );
      }
      ref = detected;
    }

    _log(
      LoggingLevel.info,
      'list_sdk_source_files: sdk=flutter ref=$ref${package != null ? ' package=$package' : ''}'
      '${rawDirectory != null ? ' directory=$rawDirectory' : ''}'
      '${fileExtension != null ? ' ext=$fileExtension' : ''}',
    );

    switch (await _astAccess.sourceFiles('flutter_sdk', ref)) {
      case PubDevFailure(:final error):
        return ToolResponse.error(error);
      case PubDevSuccess(:final value):
        return _ok(
          resolvedVersion: ref,
          sdk: 'flutter',
          package: package,
          files: value,
          prefix: package == null ? null : 'packages/$package/lib/',
          rawDirectory: rawDirectory,
          fileExtension: fileExtension,
        );
    }
  }

  CallToolResult _ok({
    required String resolvedVersion,
    required String sdk,
    required Map<String, String> files,
    String? library,
    String? package,
    String? prefix,
    String? rawDirectory,
    String? fileExtension,
  }) {
    var paths = files.keys.toList();
    if (prefix != null) {
      paths = paths.where((p) => p.startsWith(prefix)).toList();
    }
    paths = paths.where((p) => matchesDirectoryFilter(p, rawDirectory)).toList();
    if (fileExtension != null && fileExtension.isNotEmpty) {
      paths = paths.where((p) => p.endsWith(fileExtension)).toList();
    }
    paths.sort();

    return ToolResponse.ok({
      'sdk': sdk,
      'library': ?library,
      'package': ?package,
      'files': paths,
    }, resolvedVersion: resolvedVersion);
  }

  /// Validates [raw] as a single non-empty path segment: no `/`, no `..`, no
  /// bare `.`.
  static bool _isValidSegment(String raw) =>
      raw.isNotEmpty && !raw.contains('/') && raw != '..' && raw != '.';
}
