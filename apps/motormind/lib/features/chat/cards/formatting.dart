/// Formatting for values that come out of tool results. Every number on a
/// card passes through here, and every number here came from a calculation
/// (ADR 0002): these helpers format, they never compute.
library;

import 'package:advisor_core/advisor_core.dart';

/// Formats a dollar amount with thousands separators; `cents: false` rounds
/// to whole dollars. Non-numbers pass through as text so a card never crashes
/// on an unexpected field.
String money(Object? v, {bool cents = true}) {
  if (v is! num) return v?.toString() ?? '';
  final whole = v.abs().truncate();
  final fraction = cents ? '.${((v.abs() - whole) * 100).round().toString().padLeft(2, '0')}' : '';
  final rounded = cents ? whole : v.abs().round();
  return '${v < 0 ? '-' : ''}\$${groupThousands(rounded)}$fraction';
}

/// Formats a fraction (0.0699) as a percentage ("6.99%").
String percent(Object? v) => v is num ? '${(v * 100).toStringAsFixed(2)}%' : '';

/// Formats a count with thousands separators and no decimals ("45,000").
String thousands(Object? v) => v is num ? groupThousands(v.round()) : '';

/// Turns a camelCase or snake_case result key into a sentence-case label
/// ("totalCost" to "Total cost") for cards that have no hand-written label
/// for a field. Sentence case, because that is how every hand-written label
/// in the cards reads.
String labelFor(String key) {
  final spaced = key
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]!.toLowerCase()}')
      .replaceAll('_', ' ');
  return spaced[0].toUpperCase() + spaced.substring(1);
}

/// The `outputs` map of a finance result, or empty when there is none.
Map<String, Object?> outputsOf(ToolResult? r) =>
    (r?.result?['outputs'] as Map?)?.cast<String, Object?>() ?? const {};

/// The `inputs` map of a finance result (what the person or profile supplied).
Map<String, Object?> inputsOf(ToolResult? r) =>
    (r?.result?['inputs'] as Map?)?.cast<String, Object?>() ?? const {};

/// The assumptions a calculation leaned on, each with a description, value,
/// source and date, so a card can show them under the numbers.
List<Map<String, Object?>> assumptionsOf(ToolResult? r) =>
    (r?.result?['assumptions'] as List?)?.map((a) => (a as Map).cast<String, Object?>()).toList() ??
    const [];

/// The listings in a `find_vehicles` result, typed, so cards and signals
/// never index a map by string.
List<VehicleListing> listingsOf(ToolResult? r) => [
  for (final l in (r?.result?['listings'] as List?) ?? const [])
    VehicleListing.fromJson((l as Map).cast<String, Object?>()),
];
