/// Tarball → AST access for the two AST-backed tool handlers.
///
/// [AstAccess] concentrates the "load the tarball, find the file, parse it,
/// find the member" ritual that previously existed as byte-identical or
/// near-twin private helpers in `get_source_slice.dart` and
/// `get_throw_statements.dart`: `_getOrParseAst`/`_loadSourceFiles` (byte-
/// identical in both files) and `_membersForDecl` plus the
/// `_normalizeMemberName`/`_normalizeMethodName` member-name normalizers
/// (near-twins — see `member` for the union of behaviour they now share).
///
/// [AstAccess] adds no caching of its own — `fileText`, `unit`, and
/// `sourceFiles` all resolve through the `sourceFiles`/`ast` [KeyedCache]
/// facades supplied at construction (from `CacheRegistry`, ADR-0005).
library;

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';

import '../cache/cache_registry.dart';
import '../cache/keyed_cache.dart';
import '../data/domain_error.dart';

/// Resolves package source files and their parsed ASTs for the AST-backed
/// tool handlers (`get_source_slice`, `get_throw_statements`).
///
/// Constructed once and shared by both handlers so a package version's
/// tarball is downloaded, and each of its files parsed, at most once per
/// cache TTL window regardless of which handler triggers the fetch.
final class AstAccess {
  /// Creates an [AstAccess] over the shared `sourceFiles` and `ast`
  /// [KeyedCache] facades (from `CacheRegistry`) — pass the same instances
  /// used to construct the registry so both handlers share both caches.
  const AstAccess({
    required KeyedCache<SourceFilesId, Map<String, String>> sourceFiles,
    required KeyedCache<AstSnapshotId, ParseStringResult> ast,
  }) : _sourceFilesCache = sourceFiles,
       _ast = ast;

  final KeyedCache<SourceFilesId, Map<String, String>> _sourceFilesCache;
  final KeyedCache<AstSnapshotId, ParseStringResult> _ast;

  // ─── File access ────────────────────────────────────────────────────────

  /// Returns every source file extracted from [package] [version]'s tarball,
  /// as a path→content map.
  ///
  /// Not one of `get_source_slice`/`get_throw_statements`'s three per-file
  /// operations (`fileText`, `unit`, `member`) — it exists because both
  /// handlers lose direct access to the raw `sourceFiles` facade (per the
  /// handler-deepening spec) yet still need to enumerate every file in a
  /// package to scan for a class or top-level function that could live in
  /// any of them. `list_package_source_files` stays on the raw facade
  /// directly (listing, not AST access) and does not use this module.
  Future<PubDevResult<Map<String, String>>> sourceFiles(String package, String version) =>
      _sourceFilesCache.resolve((name: package, version: version));

  /// Returns the raw content of [path] within [package] [version]'s tarball.
  ///
  /// The Source Slice line-range mode needs no AST, so it resolves through
  /// this method directly rather than [unit].
  ///
  /// Fails with [DomainErrors.sourceFileNotFound] when [path] is absent from
  /// the tarball; the suggestion names up to three files sharing [path]'s
  /// filename, or falls back to pointing at `list_package_source_files` when
  /// none match.
  Future<PubDevResult<String>> fileText(String package, String version, String path) async {
    final Map<String, String> files;
    switch (await sourceFiles(package, version)) {
      case PubDevFailure(:final error):
        return PubDevFailure(error);
      case PubDevSuccess(:final value):
        files = value;
    }

    final content = files[path];
    if (content == null) {
      return PubDevFailure(
        DomainError(
          code: DomainErrors.sourceFileNotFound,
          message: 'Source file "$path" not found in $package $version.',
          suggestion: _closestMatchSuggestion(path, files.keys),
        ),
      );
    }
    return PubDevSuccess(content);
  }

  // ─── AST parsing ────────────────────────────────────────────────────────

  /// Returns the parsed AST for [path] within [package] [version]'s tarball,
  /// resolving through the shared `ast` facade so the same file is never
  /// parsed twice across a single agent turn.
  ///
  /// Fails with [DomainErrors.sourceFileNotFound] (via [fileText]) when
  /// [path] is absent from the tarball.
  Future<PubDevResult<ParseStringResult>> unit(String package, String version, String path) async {
    switch (await fileText(package, version, path)) {
      case PubDevFailure(:final error):
        return PubDevFailure(error);
      case PubDevSuccess(:final value):
        final result = await _ast.resolve((
          name: package,
          version: version,
          path: path,
          content: value,
        ));
        return switch (result) {
          PubDevSuccess() => result,
          // The `ast` facade's fetch closure always returns PubDevSuccess —
          // see CacheRegistry.ast.
          PubDevFailure(:final error) => throw StateError('unexpected AST parse failure: $error'),
        };
    }
  }

  // ─── Member lookup ──────────────────────────────────────────────────────

  /// Looks up members of the type named [className] as declared somewhere in
  /// [unit] (a [ClassDeclaration], [MixinDeclaration], [ExtensionDeclaration],
  /// or [EnumDeclaration]).
  ///
  /// Returns `null` when [unit] declares no type named [className].
  /// Otherwise returns that type's member declarations: every member when
  /// [memberName] is omitted (the entire-class scan `get_throw_statements`
  /// performs), or only the members whose name resolves to [memberName]
  /// after normalization when [memberName] is given — an empty list when the
  /// type is declared but has no matching member, or two entries when an
  /// accessor pair (a getter and setter) share [memberName].
  ///
  /// Name matching unifies the two near-twin normalizers this module
  /// replaces (`_normalizeMemberName` in `get_source_slice.dart`,
  /// `_normalizeMethodName` in `get_throw_statements.dart` — identical logic
  /// under different names): `new` matches the unnamed constructor;
  /// `operator ==` and `==` both match the `operator ==` node; every other
  /// name (including other named-constructor suffixes) matches verbatim.
  /// Field declarations match by any of their variable names, compared
  /// without normalization — `get_source_slice`'s original `_findMember`
  /// supported this (a dotted `symbolName` can name a field); folding it into
  /// this shared method makes it reachable from `get_throw_statements` too,
  /// which previously had no field-matching path in its single-method scan.
  /// That is additive, not a behaviour change: a `class`+`method` request
  /// naming a field simply becomes a valid way to scan that field's
  /// initializer for throws, where it previously always returned
  /// `SYMBOL_NOT_FOUND`.
  ///
  /// If more than one top-level declaration in [unit] shares [className] —
  /// not possible in valid Dart within a single file, since that is a
  /// duplicate-declaration compile error — only the first is consulted.
  /// `get_source_slice`'s original dotted lookup defensively kept scanning
  /// further same-named declarations for a member match; that branch is
  /// unreachable for any file that actually compiles, so it is not
  /// preserved here.
  List<ClassMember>? member(CompilationUnit unit, String className, {String? memberName}) {
    for (final decl in unit.declarations) {
      final members = _membersForDecl(decl, className);
      if (members == null) continue;
      if (memberName == null) return members.toList();

      final normalized = _normalizeName(memberName);
      return members.where((m) {
        if (m is MethodDeclaration) return m.name.lexeme == normalized;
        if (m is ConstructorDeclaration) return (m.name?.lexeme ?? '') == normalized;
        if (m is FieldDeclaration) {
          return m.fields.variables.any((v) => v.name.lexeme == memberName);
        }
        return false;
      }).toList();
    }
    return null;
  }

  /// Returns the class-member list for [decl] if it declares a type named
  /// [className], or `null` when [decl] is not a matching type declaration.
  static Iterable<ClassMember>? _membersForDecl(CompilationUnitMember decl, String className) {
    if (decl is ClassDeclaration) {
      if (decl.namePart.typeName.lexeme != className) return null;
      final body = decl.body;
      return body is BlockClassBody ? body.members : const <ClassMember>[];
    }
    if (decl is MixinDeclaration) {
      if (decl.name.lexeme != className) return null;
      final body = decl.body;
      return body is BlockClassBody ? body.members : const <ClassMember>[];
    }
    if (decl is ExtensionDeclaration) {
      if (decl.name?.lexeme != className) return null;
      final body = decl.body;
      return body is BlockClassBody ? body.members : const <ClassMember>[];
    }
    if (decl is EnumDeclaration) {
      if (decl.namePart.typeName.lexeme != className) return null;
      return decl.body.members;
    }
    return null;
  }

  /// Normalises [name] to the lexeme used in the AST: `new` for the unnamed
  /// constructor, the bare operator token for `operator `-prefixed names.
  static String _normalizeName(String name) {
    if (name == 'new') return '';
    const prefix = 'operator ';
    if (name.startsWith(prefix)) return name.substring(prefix.length).trim();
    return name;
  }

  // ─── Utility helpers ────────────────────────────────────────────────────

  static String _closestMatchSuggestion(String path, Iterable<String> keys) {
    final filename = path.split('/').last.toLowerCase();
    final matches = keys.where((k) => k.split('/').last.toLowerCase() == filename).toList();
    if (matches.isNotEmpty) {
      final quoted = matches.take(3).map((p) => '"$p"').join(', ');
      return 'Did you mean: $quoted?';
    }
    return 'Call list_package_source_files to browse available paths.';
  }
}
