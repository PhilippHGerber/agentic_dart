/// Pure symbol-bounded slicing shared by every tool handler that extracts a
/// named declaration's source from a parsed AST — `get_source_slice`'s
/// symbol-bounded mode and `get_sdk_source_slice`'s symbol-bounded mode.
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/source/line_info.dart';

import '../analysis/ast_access.dart';

/// The result of locating a symbol's AST node and, when requested,
/// truncating it to fit within `maxLines`.
final class SymbolBoundedSlice {
  /// Creates a [SymbolBoundedSlice].
  const SymbolBoundedSlice({
    required this.lineStart,
    required this.effectiveLineEnd,
    required this.truncated,
    required this.content,
  });

  /// 1-based inclusive first line of the symbol's declaration.
  final int lineStart;

  /// The true last line of the declaration — its real end line even when
  /// [truncated] — so callers can drill in with a follow-up line-range read.
  final int effectiveLineEnd;

  /// Whether [content] was collapsed to signature + omission comment + closing
  /// brace.
  final bool truncated;

  /// The extracted (possibly truncated) source.
  final String content;
}

/// Locates [symbolName] in [ast]'s compilation unit and returns its (possibly
/// [maxLines]-truncated) source, or `null` when [symbolName] matches no
/// declaration.
///
/// A bare name (e.g. `Client`) matches a top-level class, mixin, enum,
/// extension, function, typedef, or variable of that name. A dotted name
/// (e.g. `Client.send`) matches a member (method, constructor, accessor, or
/// field) named `send` inside the type `Client`, resolved via
/// [AstAccess.member] — `new` resolves to the unnamed constructor; `operator
/// ==` and `==` both resolve to the `operator ==` node.
SymbolBoundedSlice? sliceSymbol(
  AstAccess astAccess,
  ParseStringResult ast,
  String symbolName, {
  int? maxLines,
}) {
  final node = findDeclarationNode(astAccess, ast.unit, symbolName);
  if (node == null) return null;

  final content = ast.content;
  final lineInfo = ast.lineInfo;
  final startLine = lineInfo.getLocation(node.offset).lineNumber;
  final endOffset = node.end > node.offset ? node.end - 1 : node.end;
  final endLine = lineInfo.getLocation(endOffset).lineNumber;
  final nodeLineCount = endLine - startLine + 1;
  final fullSource = content.substring(node.offset, node.end);

  // No truncation requested, or the node already fits.
  if (maxLines == null || nodeLineCount <= maxLines) {
    return SymbolBoundedSlice(
      lineStart: startLine,
      effectiveLineEnd: endLine,
      truncated: false,
      content: fullSource,
    );
  }

  final truncatedSource = _truncateToSignature(content, node, lineInfo, startLine, endLine);
  // If there was no brace body to elide, fall back to returning the full
  // source untruncated rather than an arbitrary line cut.
  if (truncatedSource == null) {
    return SymbolBoundedSlice(
      lineStart: startLine,
      effectiveLineEnd: endLine,
      truncated: false,
      content: fullSource,
    );
  }

  return SymbolBoundedSlice(
    lineStart: startLine,
    effectiveLineEnd: endLine,
    truncated: true,
    content: truncatedSource,
  );
}

// ─── Symbol lookup ─────────────────────────────────────────────────────────

/// Finds the AST node for [symbolName] within [unit], or `null` if absent.
///
/// A bare name matches a top-level declaration directly. A dotted name
/// (`Type.member`) delegates to [AstAccess.member] for the class-member
/// lookup and name normalization, taking the first match when an accessor
/// pair shares the member name.
///
/// Shared with `get_api_diff`'s `includeSignatureChanges` mode, which locates
/// the same declaration in two package versions' source before rendering and
/// comparing their signatures.
AstNode? findDeclarationNode(AstAccess astAccess, CompilationUnit unit, String symbolName) {
  final dot = symbolName.indexOf('.');
  if (dot > 0) {
    final typeName = symbolName.substring(0, dot);
    final memberName = symbolName.substring(dot + 1);
    final members = astAccess.member(unit, typeName, memberName: memberName);
    return members == null || members.isEmpty ? null : members.first;
  }

  for (final decl in unit.declarations) {
    if (_declMatches(decl, symbolName)) return decl;
  }
  return null;
}

/// Whether top-level [decl] declares a symbol named [name].
bool _declMatches(CompilationUnitMember decl, String name) {
  if (decl is ClassDeclaration) return decl.namePart.typeName.lexeme == name;
  if (decl is MixinDeclaration) return decl.name.lexeme == name;
  if (decl is EnumDeclaration) return decl.namePart.typeName.lexeme == name;
  if (decl is ExtensionDeclaration) return decl.name?.lexeme == name;
  if (decl is FunctionDeclaration) return decl.name.lexeme == name;
  if (decl is TypeAlias) return decl.name.lexeme == name;
  if (decl is TopLevelVariableDeclaration) {
    return decl.variables.variables.any((v) => v.name.lexeme == name);
  }
  return false;
}

// ─── Truncation ─────────────────────────────────────────────────────────────

/// Collapses [node]'s body to signature + opening brace + omission comment +
/// closing brace. Returns `null` when the node has no brace-delimited body on
/// a line strictly before its last line (nothing meaningful to elide).
String? _truncateToSignature(
  String content,
  AstNode node,
  LineInfo lineInfo,
  int startLine,
  int endLine,
) {
  final braceIdx = content.indexOf('{', node.offset);
  if (braceIdx < 0 || braceIdx >= node.end) return null;

  final braceLine = lineInfo.getLocation(braceIdx).lineNumber;
  final omittedCount = endLine - braceLine - 1;
  if (omittedCount <= 0) return null;

  // Signature: node start through the end of the opening-brace line.
  final sigEndOffset = braceLine < lineInfo.lineCount
      ? lineInfo.getOffsetOfLine(braceLine)
      : content.length;
  final signature = content.substring(node.offset, sigEndOffset).trimRight();

  // Closing: the whole last line of the node (leading indent preserved).
  final closing = content.substring(lineInfo.getOffsetOfLine(endLine - 1), node.end).trimRight();
  final closingIndent = closing.substring(0, closing.length - closing.trimLeft().length);

  return '$signature\n'
      '$closingIndent  // ... $omittedCount lines omitted ...\n'
      '$closing';
}
