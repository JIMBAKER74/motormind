import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/scroll_cut.dart';
import '../browser/browser_pane.dart';
import '../chat/cards/formatting.dart';
import '../chat/chat_service.dart';
import '../chat/chat_strings.dart';
import '../chat/result_card.dart';
import '../search/search_service.dart';
import 'stage.dart';

/// One identity for the web pane wherever the stage puts it (full, or a
/// strip above the cards during a read), so moving it never recreates the
/// platform view and reloads the page.
final GlobalKey _paneKey = GlobalKey(debugLabel: 'web-pane');

/// Height of the page strip shown above the cards while the app reads a
/// page: enough to see it move, not enough to read it.
const double _readingStripHeight = 112;

/// The web pane is injectable so widget tests do not need a platform webview.
final webPaneBuilderProvider = Provider<Widget Function()>(
  (ref) =>
      () => const BrowserPane(),
);

/// Renders the stage: a thin mode row (Web | Cards), then either the browser
/// pane or the focused card with the others as chips.
class StageView extends ConsumerWidget {
  const StageView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = ref.watch(stageProvider);
    final search = ref.watch(searchProvider);
    final hasCards = stage.cards.isNotEmpty;
    final showingCards = stage.mode == StageMode.cards && hasCards;
    final pane = KeyedSubtree(key: _paneKey, child: ref.watch(webPaneBuilderProvider)());
    // The pill counts what the person sees: listings when the stage holds
    // them, cards otherwise (interim; design notes Q77).
    final tiles = stage.cards.fold<int>(0, (n, c) => n + listingsOf(c.result).length);
    final cardsLabel = !hasCards ? 'Cards' : 'Cards · ${tiles > 0 ? tiles : stage.cards.length}';
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
          child: Row(
            children: [
              SegmentedButton<StageMode>(
                key: const Key('stage-mode'),
                segments: [
                  const ButtonSegment(
                    value: StageMode.web,
                    icon: Icon(Icons.public, size: 16),
                    label: Text('Web'),
                  ),
                  ButtonSegment(
                    value: StageMode.cards,
                    icon: const Icon(Icons.dashboard_customize_outlined, size: 16),
                    label: Text(cardsLabel),
                    enabled: hasCards,
                  ),
                ],
                selected: {showingCards ? StageMode.cards : StageMode.web},
                onSelectionChanged: (s) {
                  ref.read(stageProvider.notifier).setMode(s.first);
                  // Coming back from the page: whatever the person's browsing
                  // loaded (lazy images) is read off the page as it is.
                  if (s.first == StageMode.cards) {
                    ref.read(searchProvider.notifier).refreshImages();
                  }
                },
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
              ),
            ],
          ),
        ),
        // While the app reads a page, the page is a short strip that can be
        // seen moving, labeled as the read it is, and the cards keep the
        // room (the owner's note: an unlabeled scroll looks like a bug).
        if (search.applying && stage.mode != StageMode.web)
          SizedBox(
            key: const Key('reading-strip'),
            height: _readingStripHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                pane,
                Align(
                  alignment: Alignment.bottomLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    color: Theme.of(context).colorScheme.surface.withValues(alpha: 0.85),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          ChatStrings.readingSite(search.siteName),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        Expanded(
          child: showingCards
              ? _Cards(stage: stage, focused: stage.focused!)
              : (search.applying && stage.mode != StageMode.web)
              ? Center(
                  child: Text(
                    ChatStrings.readingSite(search.siteName),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                )
              : pane,
        ),
      ],
    );
  }
}

class _Cards extends ConsumerStatefulWidget {
  const _Cards({required this.stage, required this.focused});

  final StageState stage;
  final ShownComponent focused;

  /// Height of the chip strip that lists the other cards.
  static const _chipStripHeight = 40.0;

  @override
  ConsumerState<_Cards> createState() => _CardsState();
}

class _CardsState extends ConsumerState<_Cards> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stage = widget.stage;
    final focused = widget.focused;
    return Column(
      key: const Key('stage'),
      children: [
        if (stage.cards.length > 1)
          SizedBox(
            height: _Cards._chipStripHeight,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [
                for (var i = 0; i < stage.cards.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6, top: 4, bottom: 4),
                    child: ChoiceChip(
                      key: Key('stage-chip-$i'),
                      label: Text(cardSummary(stage.cards[i])),
                      selected: i == stage.focus.clamp(0, stage.cards.length - 1),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => ref.read(stageProvider.notifier).focusCard(i),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: ScrollCut(
            controller: _scroll,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: ResultCard(
                shown: focused,
                onChoice: (id, label) =>
                    ref.read(chatServiceProvider.notifier).choose(id, label, source: focused),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One-line label for a card chip. Components without a hand-written label
/// fall back to their registry name on purpose; the payment and trade
/// chips carry the one number a person would look for.
String cardSummary(ShownComponent s) {
  final o = outputsOf(s.result);
  return switch (s.request.component.id) {
    'payment_summary' ||
    'payment_breakdown' => 'Payment ${money(o['monthlyPayment'], cents: false)}/mo',
    'trade_equity_card' => 'Trade ${money(o['equity'], cents: false)}',
    'affordability_gauge' => 'Affordability',
    'vehicle_card' => 'Listings',
    'page_extract' => 'Page',
    _ => labelFor(s.request.component.id),
  };
}
