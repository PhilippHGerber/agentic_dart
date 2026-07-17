/// Shared assertion for `outputSchema`/`structuredContent` conformance tests.
library;

import 'package:dart_mcp/server.dart';
import 'package:test/test.dart';

/// Asserts that [structuredContent] validates cleanly against [tool]'s
/// declared `outputSchema`.
///
/// Fails the test if [tool] has no `outputSchema` at all, rather than
/// silently skipping — every tool exercised by this helper is expected to
/// declare one.
void expectConformsToOutputSchema(Tool tool, Map<String, Object?>? structuredContent) {
  final schema = tool.outputSchema;
  if (schema == null) fail('${tool.name} has no outputSchema');
  expect(
    schema.validate(structuredContent),
    isEmpty,
    reason: '${tool.name} structuredContent failed outputSchema validation',
  );
}
