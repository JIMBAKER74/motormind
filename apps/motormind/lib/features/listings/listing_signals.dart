import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// What the person did with listings: viewed (opened the detail), liked,
/// dismissed. A summary of makes reaches the model with each turn; proposing
/// a sort or filter from it is the next step and will only ever be a
/// proposal, never a silent change.
class ListingSignals {
  const ListingSignals({this.viewed = const {}, this.liked = const {}, this.dismissed = const {}});

  final Set<String> viewed;
  final Set<String> liked;
  final Set<String> dismissed;

  ListingSignals copyWith({Set<String>? viewed, Set<String>? liked, Set<String>? dismissed}) =>
      ListingSignals(
        viewed: viewed ?? this.viewed,
        liked: liked ?? this.liked,
        dismissed: dismissed ?? this.dismissed,
      );
}

/// Session-scoped listing signals.
final listingSignalsProvider = NotifierProvider<ListingSignalsNotifier, ListingSignals>(
  ListingSignalsNotifier.new,
);

/// Records viewed, liked and dismissed listings by a stable key.
final class ListingSignalsNotifier extends Notifier<ListingSignals> {
  @override
  ListingSignals build() => const ListingSignals();

  /// "title|price" with whole dollars, so the same car read twice counts
  /// once and the key reads well in widget tests.
  static String keyFor(VehicleListing l) => '${l.title}|${l.price?.round()}';

  void markViewed(VehicleListing l) => state = state.copyWith(viewed: {...state.viewed, keyFor(l)});

  void toggleLiked(VehicleListing l) {
    final k = keyFor(l);
    final liked = {...state.liked};
    if (!liked.remove(k)) liked.add(k);
    state = state.copyWith(liked: liked, dismissed: {...state.dismissed}..remove(k));
  }

  void dismiss(VehicleListing l) {
    final k = keyFor(l);
    state = state.copyWith(dismissed: {...state.dismissed, k}, liked: {...state.liked}..remove(k));
  }

  /// A short line for the model's context ("viewed 3 (Honda); liked 1
  /// (Honda)"). Only makes are named, so the model cannot turn this into a
  /// figure it then quotes.
  String? summary(List<VehicleListing> listings) {
    if (state.viewed.isEmpty && state.liked.isEmpty) return null;
    final viewedMakes = _makesIn(listings, state.viewed);
    final likedMakes = _makesIn(listings, state.liked);
    final parts = <String>[
      if (state.viewed.isNotEmpty)
        'viewed ${state.viewed.length}${viewedMakes.isEmpty ? '' : ' (${viewedMakes.join(', ')})'}',
      if (state.liked.isNotEmpty)
        'liked ${state.liked.length}${likedMakes.isEmpty ? '' : ' (${likedMakes.join(', ')})'}',
    ];
    return parts.join('; ');
  }

  /// The distinct makes among [listings] whose key is in [keys], in the
  /// order they appear.
  static Set<String> _makesIn(List<VehicleListing> listings, Set<String> keys) => {
    for (final l in listings)
      if (keys.contains(keyFor(l)) && l.make != null) l.make!,
  };
}
