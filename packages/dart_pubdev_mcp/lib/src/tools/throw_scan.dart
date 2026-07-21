/// Pure throw-statement scanning shared by `get_throw_statements` and
/// `get_sdk_throw_statements` — the per-member/per-function AST walk neither
/// tool needs to duplicate. Mirrors `symbol_bounded_slice.dart`'s role for
/// `get_source_slice`/`get_sdk_source_slice`.
library;

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

/// Returns the display name of [member], or `null` for field declarations.
String? memberName(ClassMember member) {
  if (member is MethodDeclaration) return member.name.lexeme;
  if (member is ConstructorDeclaration) {
    final name = member.name?.lexeme;
    return name ?? 'new';
  }
  return null;
}

/// Finds the first top-level function named [name] declared in [unit].
FunctionDeclaration? findTopLevelFunction(CompilationUnit unit, String name) {
  for (final decl in unit.declarations) {
    if (decl is FunctionDeclaration && decl.name.lexeme == name) {
      return decl;
    }
  }
  return null;
}

/// Sorts [paths] so `.dart` files under `lib/` are searched before other
/// directories, dropping non-`.dart` paths entirely.
List<String> sortedDartPaths(Iterable<String> paths) => [
  ...paths.where((k) => k.endsWith('.dart') && k.startsWith('lib/')),
  ...paths.where((k) => k.endsWith('.dart') && !k.startsWith('lib/')),
];

/// Recursively collects throw and rethrow expressions from [node] into
/// [results].
///
/// [className] and [methodName] tag class-member results; [functionName]
/// tags top-level-function results. `rethrow` statements produce a record
/// with `thrown_type == "rethrow"`.
void collectThrows(
  AstNode node,
  LineInfo lineInfo,
  String source,
  String filePath,
  String? className,
  String? methodName,
  String? functionName,
  List<Map<String, Object?>> results,
) {
  _visitThrows(node, (Expression throwLike) {
    final contextNode = _contextNodeFor(throwLike);
    final thrownType = throwLike is ThrowExpression ? _thrownType(throwLike.expression) : 'rethrow';
    results.add({
      'file': filePath,
      'class': ?className,
      'method': ?methodName,
      'function': ?functionName,
      'thrown_type': thrownType,
      'context': _contextSnippet(contextNode, throwLike, source, lineInfo),
    });
  });
}

// ─── AST traversal ────────────────────────────────────────────────────────────

/// Recursively visits [node] and calls [onThrowLike] for each
/// [ThrowExpression] or [RethrowExpression].
///
/// Does not recurse into [FunctionExpression] nodes (closures / lambdas) —
/// throws inside anonymous functions are not direct throws of the enclosing
/// method scope.
void _visitThrows(AstNode node, void Function(Expression) onThrowLike) {
  if (node is ThrowExpression) {
    onThrowLike(node);
    return; // Do not recurse deeper from a throw.
  }
  if (node is RethrowExpression) {
    onThrowLike(node);
    return; // Do not recurse deeper from a rethrow.
  }
  if (node is FunctionExpression) {
    return; // Suppress recursion into anonymous functions.
  }
  for (final entity in node.childEntities) {
    if (entity is AstNode) {
      _visitThrows(entity, onThrowLike);
    }
  }
}

/// Returns the nearest enclosing node that provides meaningful context for
/// [node].
///
/// Walks up the parent chain:
/// - Returns immediately on control-flow statements (`if`, `switch`, `for`,
///   `while`, `do`, `try`) — these give the richest context.
/// - Tracks the most-recently-seen non-[Block] [Statement] as a fallback.
/// - Stops at [FunctionBody] / [MethodDeclaration] / [FunctionDeclaration]
///   boundaries to avoid leaking context into sibling nodes.
AstNode _contextNodeFor(Expression node) {
  AstNode? lastNonBlockStatement;
  var current = node.parent;
  while (current != null) {
    if (current is FunctionBody || current is MethodDeclaration || current is FunctionDeclaration) {
      break;
    }
    if (current is IfStatement ||
        current is SwitchStatement ||
        current is ForStatement ||
        current is WhileStatement ||
        current is DoStatement ||
        current is TryStatement) {
      return current;
    }
    if (current is Statement && current is! Block) {
      lastNonBlockStatement = current;
    }
    current = current.parent;
  }
  return lastNonBlockStatement ?? node;
}

/// Extracts up to three lines of source around [throwLike] within
/// [contextNode].
String _contextSnippet(
  AstNode contextNode,
  AstNode throwLike,
  String source,
  LineInfo lineInfo,
) {
  const maxLines = 3;

  final contextStartLine = lineInfo.getLocation(contextNode.offset).lineNumber - 1;
  final contextEndOffset = contextNode.end > contextNode.offset
      ? contextNode.end - 1
      : contextNode.end;
  final contextEndLine = lineInfo.getLocation(contextEndOffset).lineNumber - 1;
  final throwLine = lineInfo.getLocation(throwLike.offset).lineNumber - 1;

  var startLine = throwLine > contextStartLine ? throwLine - 1 : throwLine;
  if (startLine < contextStartLine) startLine = contextStartLine;

  var endLine = startLine + maxLines - 1;
  if (endLine > contextEndLine) {
    endLine = contextEndLine;
    startLine = endLine - maxLines + 1;
    if (startLine < contextStartLine) startLine = contextStartLine;
  }

  final startOffset = lineInfo.getOffsetOfLine(startLine);
  final endOffset = endLine + 1 < lineInfo.lineCount
      ? lineInfo.getOffsetOfLine(endLine + 1)
      : source.length;
  return source.substring(startOffset, endOffset).trimRight();
}

// ─── Thrown type extraction ───────────────────────────────────────────────────

/// Extracts the type name from the thrown [expr].
///
/// Handles:
/// - [InstanceCreationExpression]: `throw new/const SomeError(...)`
/// - [MethodInvocation]: `throw SomeError(...)` (no-new syntax) or
///   `throw SomeError.named(...)`
/// - [SimpleIdentifier]: `throw someVariable`
/// - [PrefixedIdentifier]: `throw SomeError.instance` (prefix is the class)
/// - [PropertyAccess]: chained property access
/// - [ParenthesizedExpression]: unwraps once and recurses
/// - Fallback: first uppercase token in the expression source text
String _thrownType(Expression expr) {
  if (expr is InstanceCreationExpression) {
    return expr.constructorName.type.name.lexeme;
  }
  if (expr is MethodInvocation) {
    final target = expr.target;
    if (target == null) {
      // `throw SomeError(...)` — no-new constructor, parsed as method call.
      return expr.methodName.name;
    }
    if (target is SimpleIdentifier) return target.name;
    if (target is PrefixedIdentifier) return target.identifier.name;
    return expr.methodName.name;
  }
  if (expr is SimpleIdentifier) return expr.name;
  if (expr is PrefixedIdentifier) {
    // `throw SomeError.instance` — the class is the prefix.
    return expr.prefix.name;
  }
  if (expr is PropertyAccess) {
    final target = expr.target;
    if (target is SimpleIdentifier) return target.name;
    if (target is PrefixedIdentifier) return target.prefix.name;
  }
  if (expr is ParenthesizedExpression) return _thrownType(expr.expression);
  // Fallback: first uppercase token in the expression source.
  final text = expr.toSource();
  final match = RegExp('[A-Z][A-Za-z0-9_]*').firstMatch(text);
  return match?.group(0) ?? 'Unknown';
}
