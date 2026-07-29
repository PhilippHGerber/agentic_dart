/// Tool-argument coercion shared by every handler that accepts an integer
/// argument from `CallToolRequest.arguments` — `get_source_slice`,
/// `get_sdk_source_slice`, `grep_package_source`, and `grep_sdk_source`.
library;

/// Coerces [value] to an `int`, accepting `int`, other `num` types, and
/// numeric strings. Returns `null` when [value] is `null` or not coercible.
int? asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
