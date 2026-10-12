import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/log.dart';
import '../advisor/stage.dart';
import '../browser/browser_service.dart';
import '../chat/chat_state.dart';
import '../chat/chat_strings.dart';

/// The live search: the filters as they stand, where they apply, and what the
/// last read found. A filter applies the moment it changes; there is no
/// submit step.
class SearchState {
  const SearchState({
    this.query = const SearchQuery(),
    this.siteId = 'echopark',
    this.userExpanded,
    this.applying = false,
    this.lastCount,
    this.note,
  });

  final SearchQuery query;

  /// The curated site the search applies to. The person picks it on the
  /// filters card and it sticks until changed.
  final String siteId;

  /// The person's last explicit expand or collapse of the filters card; null
  /// means the display decision decides.
  final bool? userExpanded;

  /// True while a results page is being opened and read.
  final bool applying;

  /// How many listings on the last page read matched the filters; null
  /// before the first read.
  final int? lastCount;

  /// Why the last read produced nothing, in a sentence for the person.
  final String? note;

  /// The display name of [siteId].
  String get siteName => CuratedSites.nameFor(siteId);

  SearchState copyWith({
    SearchQuery? query,
    String? siteId,
    bool? userExpanded,
    bool clearUserExpanded = false,
    bool? applying,
    int? lastCount,
    String? note,
    bool clearNote = false,
  }) => SearchState(
    query: query ?? this.query,
    siteId: siteId ?? this.siteId,
    userExpanded: clearUserExpanded ? null : (userExpanded ?? this.userExpanded),
    applying: applying ?? this.applying,
    lastCount: lastCount ?? this.lastCount,
    note: clearNote ? null : (note ?? this.note),
  );
}

/// Reads a page: the one at [url], or the page the person has open when
/// [url] is null. The web pane by default; tests inject a fake. Both the
/// live search and the model's `read_page` go through this seam, so a test
/// can stand in for the pane in one place.
typedef PageReader = Future<PageExtract> Function({String? url});

final pageReaderProvider = Provider<PageReader>(
  (ref) =>
      ({url}) => ref.read(browserProvider.notifier).readPage(url: url),
);

/// How long a run of chip taps is allowed to settle before the page loads.
/// Tests override it to zero.
final searchDebounceProvider = Provider<Duration>((ref) => const Duration(milliseconds: 500));

/// The live search. The model changes it through `update_search` and
/// `find_vehicles`, the filters card changes it directly, and free text goes
/// through `inferSearchArgs` first so the obvious cases never wait on the
/// model.
final searchProvider = NotifierProvider<SearchService, SearchState>(SearchService.new);

final class SearchService extends Notifier<SearchState> {
  Timer? _debounce;

  /// Bumped per apply so a slower, older read cannot overwrite a newer one.
  int _generation = 0;

  /// Result ids for the stage; a counter, not a clock, so tests are stable.
  int _resultSeq = 0;

  @override
  SearchState build() {
    ref.onDispose(() => _debounce?.cancel());
    // Cards first: the site's own first page of inventory is read once at
    // launch and shown as tiles, before anything is asked (design notes,
    // DD-Q21; the owner's Q71). It is the one page the pane would open
    // anyway, now the results page instead of the front page; nothing else
    // loads until the person taps or types.
    scheduleApply(delay: Duration.zero);
    return const SearchState();
  }

  CuratedSite get site => CuratedSites.byId(state.siteId) ?? CuratedSites.defaultSite;

  /// Chooses where to look and re-applies the current filters there; with
  /// nothing filtered yet that is the site's first page of inventory.
  void selectSite(String id) {
    if (CuratedSites.byId(id) == null) return;
    state = state.copyWith(siteId: id, clearNote: true);
    scheduleApply(delay: Duration.zero);
  }

  /// Records the person's expand or collapse of the filters card; null hands
  /// the decision back to the display rules.
  void setExpanded(bool? expanded) =>
      state = state.copyWith(userExpanded: expanded, clearUserExpanded: expanded == null);

  /// Merges [args] (`update_search` shape) and applies. Returns the new
  /// query. A change clears the person's manual expand or collapse: that
  /// override lasts until the context changes.
  SearchQuery update(Map<String, Object?> args, {bool applyNow = true}) {
    final q = state.query.applyArgs(args);
    state = state.copyWith(query: q, clearNote: true, clearUserExpanded: true);
    if (applyNow) scheduleApply();
    return q;
  }

  /// Infers filters from a sentence and applies what was found. Returns the
  /// fields found.
  Map<String, Object?> updateFromText(String text) {
    final found = inferSearchArgs(text);
    if (found.isNotEmpty) update(found);
    return found;
  }

  void scheduleApply({Duration? delay}) {
    _debounce?.cancel();
    _debounce = Timer(delay ?? ref.read(searchDebounceProvider), () => unawaited(apply()));
  }

  /// Picks up the images the person's own browsing loaded: the open page is
  /// read again as it is (no navigation, no scrolling), images are merged
  /// into the listings already read, and the listings card is shown again
  /// when any were filled. Called when the person comes back to Cards from
  /// the web pane. Nothing happens while a search is being applied.
  Future<void> refreshImages() async {
    if (state.applying) return;
    final List<VehicleListing> fresh;
    try {
      fresh = await ref.read(browserProvider.notifier).rereadOpenPage();
    } on Exception catch (e) {
      logDev('image refresh failed: $e');
      return;
    }
    if (fresh.isEmpty) return;
    final store = ref.read(listingStoreProvider);
    final filled = store.mergeImages(fresh);
    logDev('images: filled $filled from the page as browsed');
    if (filled == 0) return;
    final q = state.query;
    _showResults(store.searchQuery(q), ref.read(browserProvider).url ?? site.home, q);
  }

  /// Opens the site's results page for the query, reads it, and shows what
  /// matched. Safe to call repeatedly; a newer call wins.
  Future<void> apply() async {
    final gen = ++_generation;
    final q = state.query;
    final url = site.urlFor(q);
    state = state.copyWith(applying: true, clearNote: true);
    ref.read(stageProvider.notifier).showWeb();
    try {
      final extract = await ref.read(pageReaderProvider)(url: url);
      if (gen != _generation) return; // superseded
      final store = ref.read(listingStoreProvider)..addAll(extract.listings);
      final results = store.searchQuery(q);
      state = state.copyWith(applying: false, lastCount: results.length);
      _showResults(results, extract.url, q);
    } on PageChallengeException catch (e) {
      if (gen == _generation) state = state.copyWith(applying: false, note: e.message);
    } on Exception catch (e) {
      logDev('search apply failed: $e');
      if (gen == _generation) {
        state = state.copyWith(applying: false, note: ChatStrings.pageReadFailed);
      }
    }
  }

  /// Puts the matches on the stage as a listings card. The card is a tool
  /// result like any other, so the numbers on it came from the page, not
  /// from the model.
  void _showResults(List<VehicleListing> results, String source, SearchQuery q) {
    final result = ToolResult(
      id: 'search-${++_resultSeq}',
      tool: AdvisorTools.findVehicles,
      args: q.toJson(),
      result: {
        'count': results.length,
        'source': source,
        'query': q.describe(),
        'listings': [for (final l in results) l.toJson()],
        if (results.isEmpty) 'note': ChatStrings.noListingsOnPage,
      },
    );
    final shown = validatedComponent(
      {'component': 'vehicle_card', 'result_id': result.id, 'title': 'Listings · ${q.describe()}'},
      id: ref.read(componentIdsProvider).next(),
      resultTool: AdvisorTools.findVehicles,
      result: result,
    );
    if (shown == null) return;
    final stage = ref.read(stageProvider.notifier);
    // One listings card at a time: the newest search replaces the last.
    stage.removeWhere((s) => s.result?.tool == AdvisorTools.findVehicles);
    // Cards come forward as soon as a search finds something; the page
    // stays one tap away, and the display decision may still choose it.
    stage.show(shown, bringForward: results.isNotEmpty);
  }
}
