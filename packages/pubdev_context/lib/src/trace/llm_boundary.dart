/// The central LLM-boundary capture for the Wire Trace.
///
/// [LlmBoundaryTracer] wraps a tool implementation or a resource-template
/// handler so that, per request, it:
///
///   1. allocates a Correlation Id,
///   2. logs the inbound call (method, name, full arguments),
///   3. runs the handler inside a [Zone] carrying the id (see
///      [wireTraceZoneIdKey]) so the pub.dev client can attribute its own lines
///      to the same request, and
///   4. logs the outbound result (name, `isError`, total duration, result size,
///      truncated preview).
///
/// It is installed once, at tool-registration and resource-template-registration
/// time, so every current and future handler is traced without editing handler
/// code. When tracing is disabled the wrapper is never installed and nothing
/// here runs (see the server wiring).
library;

import 'dart:async';
import 'dart:convert';

import 'package:dart_mcp/server.dart';

import 'wire_trace.dart';

/// Wraps MCP handlers to capture the LLM boundary in a [WireTrace].
final class LlmBoundaryTracer {
  /// Creates a tracer that writes to the given [WireTrace].
  const LlmBoundaryTracer(this._trace);

  final WireTrace _trace;

  /// Wraps a tool [impl] so each call is traced under its own Correlation Id.
  FutureOr<CallToolResult> Function(CallToolRequest) wrapTool(
    FutureOr<CallToolResult> Function(CallToolRequest) impl,
  ) {
    return (request) {
      final id = _trace.nextCorrelationId();
      _trace.logInboundCall(
        id: id,
        method: CallToolRequest.methodName,
        name: request.name,
        argsJson: jsonEncode(request.arguments ?? const <String, Object?>{}),
      );
      final stopwatch = Stopwatch()..start();
      return runZoned(
        () async {
          try {
            final result = await impl(request);
            stopwatch.stop();
            _logToolResult(id, request.name, stopwatch.elapsed, result);
            return result;
          } on Object catch (error) {
            stopwatch.stop();
            _logThrow(id, request.name, stopwatch.elapsed, error);
            rethrow;
          }
        },
        zoneValues: {wireTraceZoneIdKey: id},
      );
    };
  }

  /// Wraps a resource-template [handler] so each read is traced.
  ///
  /// A resource read carries no arguments beyond its URI, so the inbound line's
  /// name is the URI itself and no `args:` line is written. The handler is only
  /// registered for `pub://package/...` templates and returns non-null for any
  /// such URI, so exactly one wrapped handler fires and logs a result per read;
  /// a `null` return (URI matched no template) logs no result.
  FutureOr<ReadResourceResult?> Function(ReadResourceRequest) wrapResource(
    FutureOr<ReadResourceResult?> Function(ReadResourceRequest) handler,
  ) {
    return (request) {
      final id = _trace.nextCorrelationId();
      _trace.logInboundCall(
        id: id,
        method: ReadResourceRequest.methodName,
        name: request.uri,
      );
      final stopwatch = Stopwatch()..start();
      return runZoned(
        () async {
          try {
            final result = await handler(request);
            stopwatch.stop();
            if (result != null) {
              _logResourceResult(id, request.uri, stopwatch.elapsed, result);
            }
            return result;
          } on Object catch (error) {
            stopwatch.stop();
            _logThrow(id, request.uri, stopwatch.elapsed, error);
            rethrow;
          }
        },
        zoneValues: {wireTraceZoneIdKey: id},
      );
    };
  }

  void _logToolResult(
    String id,
    String name,
    Duration duration,
    CallToolResult result,
  ) {
    final text = _toolText(result);
    final isError = result.isError ?? false;
    _logResult(
      id: id,
      name: name,
      duration: duration,
      isError: isError,
      text: text,
      errorCode: isError ? _extractErrorCode(text) : null,
    );
  }

  void _logResourceResult(
    String id,
    String uri,
    Duration duration,
    ReadResourceResult result,
  ) {
    final text = _resourceText(result);
    // A resource result has no `isError` flag; a domain-error body is the sole
    // signal, so an extractable error code means the read failed.
    final code = _extractErrorCode(text);
    _logResult(
      id: id,
      name: uri,
      duration: duration,
      isError: code != null,
      text: text,
      errorCode: code,
    );
  }

  /// Writes the outbound result line. [errorCode] is supplied by the caller,
  /// which is the single place that knows whether the result is an error and so
  /// extracts the code exactly once.
  void _logResult({
    required String id,
    required String name,
    required Duration duration,
    required bool isError,
    required String text,
    String? errorCode,
  }) {
    final preview = _trace.bodyPreview(text);
    _trace.logResult(
      id: id,
      name: name,
      duration: duration,
      isError: isError,
      errorCode: isError ? errorCode : null,
      sizeBytes: utf8.encode(text).length,
      bodyPreview: isError ? null : preview,
      errorPreview: isError ? preview : null,
    );
  }

  /// Logs a handler that threw rather than returning a result. Best-effort — it
  /// records the failure and re-throwing is left to the caller.
  void _logThrow(String id, String name, Duration duration, Object error) {
    _trace.logResult(
      id: id,
      name: name,
      duration: duration,
      isError: true,
      errorCode: 'UNCAUGHT_EXCEPTION',
      errorPreview: _trace.bodyPreview(error.toString()),
    );
  }

  static String _toolText(CallToolResult result) => _joinText(
    result.content,
    isText: (content) => content.isText,
    textOf: (content) => (content as TextContent).text,
  );

  static String _resourceText(ReadResourceResult result) => _joinText(
    result.contents,
    isText: (content) => content.isText,
    textOf: (content) => (content as TextResourceContents).text,
  );

  /// Concatenates the text of every text-bearing item in [items], newline-joined.
  static String _joinText<T>(
    Iterable<T> items, {
    required bool Function(T) isText,
    required String Function(T) textOf,
  }) {
    final buffer = StringBuffer();
    for (final item in items) {
      if (isText(item)) {
        if (buffer.isNotEmpty) buffer.write('\n');
        buffer.write(textOf(item));
      }
    }
    return buffer.toString();
  }

  /// Extracts the `error.code` from an ADR-0002 error body, or `null` when
  /// [text] is not such a payload.
  static String? _extractErrorCode(String text) {
    if (text.isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, Object?>) {
        final error = decoded['error'];
        if (error is Map<String, Object?>) {
          final code = error['code'];
          if (code is String) return code;
        }
      }
    } on FormatException {
      // Not JSON — no structured error code to extract.
    }
    return null;
  }
}
