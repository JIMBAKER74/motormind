import 'dart:async';

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

/// The web pane is injectable so widget tests do not need a platform webview.
final webPaneBuilderProvider = Provider<Widget Function()>(
  (ref) =>
      () => const BrowserPane(),
);

/// Height of the page strip shown above the cards while the app reads a
/// page: enough to see it move, not enough to read it.
const double _readingStripHeight = 112;

/// Height the pane keeps while the cards have the stage. Not zero: the
/// platform view stays alive (and so does the page the person browsed) at a
/// size Android accepts, and nothing is reloaded when it comes back.
const double _parkedPaneHeight = 1;

/// How often, while the page is in view, the listings are checked against
/// the page as it is, so images the person's browsing loaded reach the
/// cards. A read of the page's HTML is well under a second on a phone.
const Duration _imageRefreshEvery = Duration(seconds: 5);

/// Renders the stage: a thin mode row (Web | Cards), the web pane, and the
/// cards. The pane is always in the same place in the tree and only changes
/// height (full in Web, a strip during a read, parked otherwise): moving a
/// platform view between parents recreated it, reloaded the page, and once
/// tripped a framework assertion on resume (2026-10-12).
class StageView extends ConsumerStatefulWidget {
  const StageView({super.key});

  @override
  ConsumerState<StageView> createState() => _StageViewState();
}

class _StageViewState extends ConsumerState<StageView> {
  Timer? _imageRefresh;

  @override
  void dispose() {
    _imageRefresh?.cancel();
    super.dispose();
  }

  /// Watches the page for images while it is in view; stops otherwise.
  void _watchImages(bool paneVisible) {
    if (paneVisible && _imageRefresh == null) {
      _imageRefresh = Timer.periodic(
        _imageRefreshEvery,
        (_) => ref.read(searchProvider.notifier).refreshImages(),
      );
    } else if (!paneVisible && _imageRefresh != null) {
      _imageRefresh!.cancel();
      _imageRefresh = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final stage = ref.watch(stageProvider);
    final search = ref.watch(searchProvider);
    final theme = Theme.of(context);
    final hasCards = stage.cards.isNotEmpty;
    final webMode = stage.mode == StageMode.web || !hasCards;
    final reading = search.applying && !webMode;
    _watchImages(webMode || reading);
    final pane = ref.watch(webPaneBuilderProvider)();
    // The pill counts cards only when there is more than one to switch
    // between (the chip strip is the switch); one card needs no number.
    final cardsLabel = stage.cards.length > 1 ? 'Cards · ${stage.cards.length}' : 'Cards';
    return LayoutBuilder(
      builder: (context, constraints) => Column(
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
                  selected: {webMode ? StageMode.web : StageMode.cards},
                  onSelectionChanged: (s) {
                    ref.read(stageProvider.notifier).setMode(s.first);
                    // Coming back from the page: whatever the person's
                    // browsing loaded is read off the page as it is.
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
          // The pane: full, a labeled strip during a read, or parked.
          SizedBox(
            key: const Key('web-pane-slot'),
            height: webMode
                ? constraints.maxHeight - _modeRowHeight
                : reading
                ? _readingStripHeight
                : _parkedPaneHeight,
            child: ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  pane,
                  if (reading)
                    Align(
                      alignment: Alignment.bottomLeft,
                      child: Container(
                        key: const Key('reading-strip'),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        color: theme.colorScheme.surface.withValues(alpha: 0.85),
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
                              style: theme.textTheme.labelSmall,
                            ),
                            const SizedBox(width: 8),
                            // The owner asked for a way to make the page big.
                            InkWell(
                              key: const Key('strip-expand'),
                              onTap: () => ref.read(stageProvider.notifier).setMode(StageMode.web),
                              child: const Icon(Icons.open_in_full, size: 14),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (!webMode)
            Expanded(
              child: hasCards
                  ? _Cards(stage: stage, focused: stage.focused!)
                  : Center(
                      child: Text(
                        ChatStrings.readingSite(search.siteName),
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
            ),
        ],
      ),
    );
  }

  /// Height of the mode row above the pane, so a full pane fills the rest.
  static const double _modeRowHeight = 46;
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
