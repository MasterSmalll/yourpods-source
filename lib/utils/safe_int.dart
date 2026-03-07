/// Safely convert a dynamic numeric value to [int].
///
/// After JSON round-tripping through SharedPreferences, Dart's `json.decode`
/// may return numeric values as `double` instead of `int`. Using a hard cast
/// (`value as int`) would throw a [TypeError] in that case. This helper
/// handles both `int` and `double` gracefully.
///
/// Returns 0 if [value] is null or not a [num].
int safeInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

/// Nullable variant — returns `null` when [value] is null.
int? safeIntOrNull(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}
