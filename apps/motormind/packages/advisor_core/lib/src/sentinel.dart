/// Marks an argument the caller left out of a `copyWith`-style method, so
/// that an explicit `null` can mean "clear this field" while omitting the
/// argument means "keep the current value".
///
/// The pattern: declare the parameter as `Object? field = unset`, then
/// resolve it with [orKeep]. A nullable parameter alone cannot tell the two
/// cases apart, and a separate `clearField` flag doubles the parameter list;
/// one shared sentinel keeps every such method identical.
const Object unset = Object();

/// [given] cast to `T?` when the caller supplied it (including an explicit
/// null), or [current] when [given] is [unset].
T? orKeep<T>(Object? given, T? current) => identical(given, unset) ? current : given as T?;
