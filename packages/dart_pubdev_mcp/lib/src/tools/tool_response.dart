/// The Tool Error / success envelope every tool handler returns through.
///
/// [ToolResponse] is the single home of the two [CallToolResult] shapes ADR-0002
/// defines: a success body carrying the "Resolved Version is the first JSON
/// key" invariant, and the `isError: true` Tool Error body. No handler builds
/// either shape by hand — this replaces the ~12 duplicated private
/// `_domainError`/`_success` builders that previously lived one per handler.
library;

import 'dart:convert';

import 'package:dart_mcp/server.dart';

import '../data/domain_error.dart';

/// Builds the two [CallToolResult] shapes every `dart_pubdev_mcp` tool handler
/// returns.
abstract final class ToolResponse {
  /// Builds a success [CallToolResult] from [payload].
  ///
  /// [payload] is almost always a `Map<String, Object?>`; `search_packages` is
  /// the sole exception, whose response body is a bare JSON array of package
  /// summaries — [payload] is typed `Object` to admit it.
  ///
  /// When [resolvedVersion] is supplied, it is inserted ahead of every key
  /// already in [payload] as `resolvedVersion` — the Resolved Version
  /// invariant every version-accepting tool response carries. [payload] must
  /// be a `Map<String, Object?>` in that case. Omit [resolvedVersion] for the
  /// two version-agnostic tools, `search_packages` and `compare_packages`.
  static CallToolResult ok(Object payload, {String? resolvedVersion}) {
    final Object body;
    if (resolvedVersion == null) {
      body = payload;
    } else {
      body = {'resolvedVersion': resolvedVersion, ...payload as Map<String, Object?>};
    }
    return CallToolResult(content: [TextContent(text: jsonEncode(body))]);
  }

  /// Builds an ADR-0002 Tool Error [CallToolResult] for [error].
  static CallToolResult error(DomainError error) =>
      CallToolResult(content: [TextContent(text: error.toJsonString())], isError: true);
}
