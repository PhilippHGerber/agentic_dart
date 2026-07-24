/// Renders a declaration's signature — everything except its
/// body/implementation — as AST-reconstructed text, for structural
/// comparison of one declaration across two package versions
/// (`get_api_diff`'s `includeSignatureChanges` mode).
library;

import 'package:analyzer/dart/ast/ast.dart';

/// Returns [node]'s declaration header, reconstructed from the AST via
/// [AstNode.toSource] with the body/implementation subtree excluded.
///
/// Reconstructing from the AST — rather than slicing the raw source text —
/// makes the result formatting-invariant: re-running `dart format` or
/// re-wrapping a long parameter list does not, by itself, read as a
/// signature change. Modifiers, types, names, type parameters, full
/// parameter lists (including default values), and — for class-like
/// declarations — `extends`/`with`/`implements` clauses are all part of the
/// rendered header; nothing is stripped from them.
///
/// Every declaration kind handled here — methods, constructors, functions,
/// and class-like declarations (class/mixin/enum/extension) — renders its
/// body as the last thing emitted by [AstNode.toSource] (confirmed against
/// `package:analyzer`'s `ToSourceVisitor`: the body is always the final
/// child visited, with nothing following it), so stripping the body's own
/// rendered text from the end of the full rendering isolates the header.
/// Field and top-level-variable declarations have no body concept; their
/// full rendering *is* the header, including the initializer expression —
/// deliberately not stripped (see issue 04's design decisions: a value-only
/// change still shows up as a real, narrower difference).
String renderDeclarationSignature(AstNode node) {
  final full = node.toSource();
  final body = _bodyOf(node);
  if (body == null) return full;

  final bodySource = body.toSource();
  if (bodySource.isEmpty || !full.endsWith(bodySource)) return full;
  return full.substring(0, full.length - bodySource.length).trimRight();
}

/// Returns the subtree rendered last within [node]'s [AstNode.toSource]
/// output — a [FunctionBody] for callable declarations, a class-body node for
/// type declarations — or `null` when [node] has no such trailing body
/// (fields, top-level variables, typedefs).
AstNode? _bodyOf(AstNode node) {
  if (node is ClassDeclaration) return node.body;
  if (node is MixinDeclaration) return node.body;
  if (node is EnumDeclaration) return node.body;
  if (node is ExtensionDeclaration) return node.body;
  if (node is MethodDeclaration) return node.body;
  if (node is ConstructorDeclaration) return node.body;
  if (node is FunctionDeclaration) return node.functionExpression.body;
  return null;
}
