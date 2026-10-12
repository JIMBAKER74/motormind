import 'listing.dart';
import 'search_query.dart';

/// Listings read during this session. Session scope is deliberate: a listing
/// is a snapshot of a page, so keeping it across conversations is a separate,
/// explicit action the person takes, not something the store does on its
/// own. `find_vehicles` searches here. Listings carry `readAt` so a card can
/// say how old its figures are once a listing outlives the page read.
class ListingStore {
  final List<VehicleListing> _all = [];

  /// [VehicleListing.dedupeKey] of every stored listing, so a page read
  /// twice costs one lookup per card rather than a scan of the store.
  final Set<String> _keys = {};

  /// Every listing read so far, in read order; unmodifiable.
  List<VehicleListing> get all => List.unmodifiable(_all);

  /// True when nothing has been read yet.
  bool get isEmpty => _all.isEmpty;

  /// Adds [listings], skipping any whose [VehicleListing.dedupeKey] matches
  /// one already stored.
  void addAll(Iterable<VehicleListing> listings) {
    for (final l in listings) {
      if (_keys.add(l.dedupeKey)) _all.add(l);
    }
  }

  /// Fills in images for stored listings that have none, from [fresh]
  /// listings read off the same page later (after the person scrolled it and
  /// the site's lazy images arrived). Matched by [VehicleListing.dedupeKey];
  /// nothing else about a stored listing changes. Returns how many were
  /// filled. The person's own browsing is the source of images; the app
  /// never scrolls a page to get them.
  int mergeImages(Iterable<VehicleListing> fresh) {
    var filled = 0;
    for (final f in fresh) {
      final url = f.imageUrl;
      if (url == null) continue;
      final i = _all.indexWhere((l) => l.imageUrl == null && l.dedupeKey == f.dedupeKey);
      if (i < 0) continue;
      final l = _all[i];
      _all[i] = VehicleListing(
        id: l.id,
        title: l.title,
        sourceUrl: l.sourceUrl,
        readAt: l.readAt,
        price: l.price,
        mileage: l.mileage,
        year: l.year,
        make: l.make,
        model: l.model,
        bodyStyle: l.bodyStyle,
        imageUrl: url,
        detailUrl: l.detailUrl ?? f.detailUrl,
      );
      filled++;
    }
    return filled;
  }

  /// Forgets every listing.
  void clear() {
    _all.clear();
    _keys.clear();
  }

  /// Searches with the live query, cheapest first, at most [limit] results.
  /// Make and model must appear in the title; any word of
  /// [SearchQuery.keywords] may. Unpriced listings never match a price
  /// bound; listings without a mileage or a year pass those bounds, since
  /// the page may simply not show them. [SearchQuery.bodyStyle] is not
  /// applied: no reader fills [VehicleListing.bodyStyle] yet, so the site's
  /// own filter is what narrows the inventory to a style.
  List<VehicleListing> searchQuery(SearchQuery q, {int limit = 8}) {
    final words = (q.keywords ?? '')
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final results = _all.where((l) {
      if (q.maxPrice != null && (l.price == null || l.price! > q.maxPrice!)) return false;
      if (q.minPrice != null && (l.price == null || l.price! < q.minPrice!)) return false;
      if (q.maxMileage != null && l.mileage != null && l.mileage! > q.maxMileage!) return false;
      if (q.minYear != null && l.year != null && l.year! < q.minYear!) return false;
      final hay = l.title.toLowerCase();
      if (q.make != null && !hay.contains(q.make!.toLowerCase())) return false;
      if (q.model != null && !hay.contains(q.model!.toLowerCase())) return false;
      if (words.isNotEmpty && !words.any(hay.contains)) return false;
      return true;
    }).toList()..sort((a, b) => (a.price ?? double.infinity).compareTo(b.price ?? double.infinity));
    return results.take(limit).toList();
  }
}
