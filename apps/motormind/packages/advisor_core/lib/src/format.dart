/// Number formatting shared by everything that writes a figure into text the
/// model or the person reads: the search summary, the prompt's profile
/// summary. One home, so a figure looks the same wherever it appears.
library;

/// Separates thousands with commas: 9500 → `9,500`, 1234567 → `1,234,567`.
/// A fractional [n] is rounded to the nearest whole number first.
String groupThousands(num n) =>
    n.round().toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');

/// Whole dollars with a sign and thousands separators (`$2,000`), or
/// `unknown` for null, so every amount in a summary reads the same way.
String wholeDollars(double? amount) => amount == null ? 'unknown' : '\$${groupThousands(amount)}';
