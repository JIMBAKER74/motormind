/// Enum lookup by name, the way a tool argument or a stored JSON value spells
/// it: `"good"`, `" Good "`, `"GOOD"`. Every enum that crosses the model or
/// the disk boundary goes through here, so the tolerance (case, surrounding
/// whitespace) is the same everywhere and a stray value never becomes a
/// `TypeError`.
library;

/// The member of [values] whose name matches [raw], ignoring case and
/// surrounding whitespace; null for null, for an unknown name and for a value
/// that is not a name at all (a number, a map). Callers that treat an unknown
/// value as "keep what was there" use this; callers that must refuse it use
/// [requireEnumByName].
T? enumByName<T extends Enum>(List<T> values, Object? raw) {
  if (raw == null) return null;
  final name = raw.toString().trim().toLowerCase();
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}

/// Like [enumByName] but throws an [ArgumentError] naming [name] and listing
/// the accepted names when [raw] is null or unknown, so a tool handler can
/// turn the message straight into the correction the model is shown.
T requireEnumByName<T extends Enum>(List<T> values, Object? raw, String name) {
  final names = values.map((value) => value.name).join(', ');
  if (raw == null) throw ArgumentError('$name is required; one of $names');
  return enumByName(values, raw) ?? (throw ArgumentError('$name must be one of $names'));
}
