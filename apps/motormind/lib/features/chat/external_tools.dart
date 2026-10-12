import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../advisor/stage.dart';
import '../browser/browser_service.dart';
import '../search/search_service.dart';

/// The app's [ExternalTools], so a test can drive a tool through a
/// [ProviderContainer] with the seams overridden.
final externalToolsProvider = Provider<ExternalTools>(ExternalTools.new);

/// The tools the turn pipeline does not own because they need the app: the
/// web pane and the live search. The pipeline calls [call] by tool name and
/// hands the returned map to the model as the tool's result.
final class ExternalTools {
  const ExternalTools(this._ref);

  final Ref _ref;

  /// How much page text the model gets from `read_page`; the rest is on
  /// screen for the person and would only cost context tokens.
  static const pageTextForModel = 1000;

  /// A page that yields at least this many listings is a results page: the
  /// model gets the listings and not the prose. Measured 2026-10-12 on a
  /// Galaxy Z Fold 4: a 4,096-token window overflowed on the third turn
  /// because every page read also carried its text.
  static const listingsMeanResultsPage = 3;

  /// Listings the model gets from one read; cards on the stage show more.
  static const listingsForModel = 8;

  /// Default number of matches returned to the model by `find_vehicles`.
  static const defaultFindLimit = 5;

  /// The search fields the model may change, in `update_search` shape.
  static const _searchFields = [
    'body_style',
    'max_price',
    'min_price',
    'make',
    'model',
    'max_mileage',
    'min_year',
    'keywords',
  ];

  Future<Map<String, Object?>> call(String name, Map<String, Object?> args) => switch (name) {
    AdvisorTools.readPage => _readPage(args),
    AdvisorTools.updateSearch || AdvisorTools.findVehicles => _search(args),
    _ => throw StateError('no handler for $name'),
  };

  /// Reads the page the person has open (or the one the model names). A
  /// human-verification page is reported, never worked around.
  Future<Map<String, Object?>> _readPage(Map<String, Object?> args) async {
    // The model may name a page to open, but only on a curated site; the
    // person can browse anywhere by hand and ask for the page they have open.
    final url = args['url']?.toString();
    if (url != null && url.isNotEmpty && BrowserService.siteIdFor(url) == null) {
      return {
        'error':
            'read_page can open pages on ${CuratedSites.all.map((s) => s.name).join(', ')} only; '
            'to read another site, ask the person to open it in the web pane first.',
      };
    }
    _ref.read(stageProvider.notifier).showWeb();
    final PageExtract extract;
    try {
      extract = await _ref.read(pageReaderProvider)(url: url);
    } on PageChallengeException catch (e) {
      return {'error': e.message};
    }
    final text = extract.text;
    final isResults = extract.listings.length >= listingsMeanResultsPage;
    return {
      'url': extract.url,
      'title': extract.title,
      if (!isResults)
        'text': text.length > pageTextForModel ? '${text.substring(0, pageTextForModel)}…' : text,
      'facts': extractListingFacts(text).toJson(),
      'listings': [for (final l in extract.listings.take(listingsForModel)) l.toModelJson()],
    };
  }

  /// Both search tools share one path: merge the model's arguments into the
  /// live filters, open the chosen site's page, read it once, and report
  /// what matched. A zero-match result says so plainly rather than letting
  /// the model guess that nothing could be read.
  Future<Map<String, Object?>> _search(Map<String, Object?> args) async {
    final search = _ref.read(searchProvider.notifier);
    final changes = <String, Object?>{
      for (final k in _searchFields)
        if (args.containsKey(k)) k: args[k],
      if (args.containsKey('vehicle_class')) 'body_style': args['vehicle_class'],
    };
    search.update(changes, applyNow: false);
    await search.apply();
    final s = _ref.read(searchProvider);
    final site = CuratedSites.byId(s.siteId)?.name ?? s.siteId;
    if (s.note != null) return {'error': s.note, 'query': s.query.describe(), 'site': site};
    final limit = (args['limit'] as num?)?.toInt() ?? defaultFindLimit;
    final results = _ref.read(listingStoreProvider).searchQuery(s.query, limit: limit);
    return {
      'query': s.query.describe(),
      'site': site,
      'count': s.lastCount ?? results.length,
      'listings': [for (final l in results) l.toModelJson()],
      if (results.isEmpty)
        'note':
            'The $site page for this search is open and was read; nothing on it matched. '
            'Say so plainly and suggest loosening a filter or trying another site.',
    };
  }
}
