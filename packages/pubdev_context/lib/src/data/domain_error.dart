/// Domain error types for pub.dev API failures.
///
/// All pub.dev client errors are represented as [DomainError] values wrapped
/// in [PubDevResult] — they are never thrown as Dart exceptions across module
/// boundaries. Callers pattern-match on [PubDevSuccess] vs [PubDevFailure] to
/// access the result or the structured error.
library;

import 'dart:convert';

/// Well-known error codes returned by the pub.dev API client.
abstract final class DomainErrors {
  /// The requested package was not found on pub.dev.
  static const packageNotFound = 'package_not_found';

  /// pub.dev rate-limited the request (HTTP 429).
  static const rateLimited = 'rate_limited';

  /// pub.dev was temporarily unavailable (HTTP 5xx).
  static const serviceUnavailable = 'service_unavailable';

  /// The response body could not be parsed.
  static const unexpectedResponse = 'unexpected_response';

  /// A request to pub.dev did not complete within the allotted time.
  static const requestTimeout = 'request_timeout';

  /// The package changelog contains no recognisable version headings.
  static const noDocumentation = 'no_documentation';

  /// A supplied parameter value is outside the accepted range or format.
  static const invalidInput = 'invalid_input';

  /// The requested symbol documentation page was not found.
  static const symbolNotFound = 'symbol_not_found';

  /// The requested package example page was not found or is empty.
  static const exampleNotFound = 'example_not_found';

  /// The requested source file was not found in the package tarball.
  static const sourceFileNotFound = 'source_file_not_found';

  /// The supplied symbol name matches more than one entry and could not be
  /// resolved unambiguously.
  static const ambiguousSymbol = 'ambiguous_symbol';

  /// The requested class (or mixin, enum, or extension) was not found in any
  /// source file of the package.
  static const classNotFound = 'class_not_found';

  /// The requested method, constructor, or accessor was not found in the
  /// specified class, or the named top-level function was not found.
  static const methodNotFound = 'method_not_found';
}

/// A structured error value returned when a pub.dev API operation fails.
///
/// Serialises to `{ "error": ..., "message": ..., "suggestion": ..., "docs": ..., "alternatives": ... }`.
/// Pass [docs] when a relevant pub.dev URL aids self-service recovery.
/// Pass [alternatives] for [DomainErrors.ambiguousSymbol] to list candidate
/// qualified names the caller can use to retry with a more specific input.
final class DomainError {
  /// Creates a [DomainError] with the required fields.
  const DomainError({
    required this.error,
    required this.message,
    required this.suggestion,
    this.docs,
    this.alternatives,
  });

  /// A short machine-readable code identifying the failure category.
  final String error;

  /// A human-readable explanation of what went wrong.
  final String message;

  /// Actionable advice for the caller to resolve the issue.
  final String suggestion;

  /// An optional URL to relevant documentation.
  final String? docs;

  /// Candidate qualified names returned with [DomainErrors.ambiguousSymbol].
  ///
  /// Each entry is a fully-qualified symbol name (e.g. `"http.Client"`) that
  /// the caller can pass as `symbol` to disambiguate the request.
  final List<String>? alternatives;

  /// Returns this error as a JSON-encodable map.
  Map<String, Object?> toJson() => {
    'error': error,
    'message': message,
    'suggestion': suggestion,
    if (docs != null) 'docs': docs,
    if (alternatives != null) 'alternatives': alternatives,
  };

  /// Returns this error encoded as a JSON string.
  String toJsonString() => jsonEncode(toJson());
}

/// The result of a pub.dev client operation — either a success or a failure.
///
/// Pattern-match against [PubDevSuccess] and [PubDevFailure] to handle both
/// cases. Never catch exceptions instead of checking this type.
sealed class PubDevResult<T> {
  const PubDevResult();
}

/// A successful [PubDevResult] carrying a typed value.
final class PubDevSuccess<T> extends PubDevResult<T> {
  /// Creates a successful result with [value].
  const PubDevSuccess(this.value);

  /// The successful value returned by the operation.
  final T value;
}

/// A failed [PubDevResult] carrying a structured [DomainError].
final class PubDevFailure<T> extends PubDevResult<T> {
  /// Creates a failure result with [error].
  const PubDevFailure(this.error);

  /// The structured error describing what went wrong.
  final DomainError error;
}
