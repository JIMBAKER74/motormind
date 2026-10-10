/// Parses a number the way a model, a person or a listing page writes one:
/// `18500`, `"$18,500"`, `"18 500"`, `"6%"`, `"0.06"`, `"50k"`, `"35K"`.
///
/// Returns null for null, for non-numeric strings and for any other type, so
/// callers decide whether a missing value is an error. Currency symbols,
/// thousands separators and whitespace are stripped; a trailing `%` divides
/// by 100 so that `"6%"` and `0.06` mean the same rate; a trailing `k` or `K`
/// multiplies by 1,000 so that `"50k"` and `50000` mean the same price or
/// odometer. One parser serves tool arguments, stored profiles, page text and
/// the narration guard, so every reader of a figure agrees on what it means.
double? parseTolerantNumber(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is! String) return null;
  var cleaned = value.replaceAll(RegExp(r'[\$,\s]'), '');
  var scale = 1.0;
  if (cleaned.endsWith('k') || cleaned.endsWith('K')) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
    scale = 1000;
  }
  if (cleaned.endsWith('%')) {
    cleaned = cleaned.substring(0, cleaned.length - 1);
    scale = 0.01;
  }
  final parsed = double.tryParse(cleaned);
  if (parsed == null) return null;
  return parsed * scale;
}
