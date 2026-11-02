import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../../services/log.dart';
import '../browser/browser_service.dart';
import '../chat/chat_panel.dart';
import '../chat/chat_service.dart';
import '../listings/listing_signals.dart';
import '../search/search_service.dart';
import 'display_agent.dart';
import 'stage.dart';
import 'tap_journal.dart';

/// The Motormind surface state machine (ADR 0006 §4). The model may
/// *request* a state through `present`; the person owns the toggle. A pin
/// that holds the state against requests is planned, not built.
final surfaceProvider = NotifierProvider<SurfaceNotifier, SurfaceState>(SurfaceNotifier.new);

final class SurfaceNotifier extends Notifier<SurfaceState> {
  @override
  SurfaceState build() => SurfaceState.collapsed;

  /// From the model.
  void request(SurfaceState next) => state = next;

  /// From the person's control.
  void userSet(SurfaceState next) => state = next;

  void cycle() => state = switch (state) {
    SurfaceState.collapsed => SurfaceState.docked,
    SurfaceState.docked => SurfaceState.fullscreen,
    SurfaceState.fullscreen => SurfaceState.collapsed,
  };
}

/// Lays out the stage and the Motormind surface for the current state:
/// a bubble over the stage, a docked split, or fullscreen. The docked split
/// follows the display decision; the keyboard rule is a hard floor.
class AdvisorSurfaceHost extends ConsumerWidget {
  const AdvisorSurfaceHost({super.key, required this.content});

  final Widget content;

  /// Stage flex (of 100) per split. "Half" leans to the stage so a card's
  /// header clears the fold; "typing" keeps a sliver so the thing being
  /// answered stays visible.
  static int stageFlexFor(StageSplit split) => switch (split) {
    StageSplit.typing => 15,
    StageSplit.third => 33,
    StageSplit.half => 55,
    StageSplit.twoThirds => 66,
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(surfaceProvider);
    // Watched from the first frame so the installed model starts loading at
    // launch, not when the panel first opens; the panel only shows the load.
    // The conversation starts itself the moment the model is ready, so the
    // opening question is waiting when the person looks, with nothing to tap
    // first ("always on": the owner, 2026-10-12).
    ref.listen(advisorModelServiceProvider, (_, models) {
      final ready = models.value?.activeId != null;
      final chat = ref.read(chatServiceProvider);
      if (ready && !chat.ready && !chat.busy) {
        unawaited(ref.read(chatServiceProvider.notifier).start());
      }
    });
    ref.watch(advisorModelServiceProvider);
    // The display decision picks Web or Cards for the stage; a manual flip
    // wins. Listened here because this host outlives the stage view.
    ref.listen(displayProvider, (_, d) => ref.read(stageProvider.notifier).applyDecision(d.stage));

    final stage = KeyedSubtree(key: stageRegionKey, child: content);
    return _TapWatch(
      child: switch (state) {
        SurfaceState.collapsed => Stack(
          children: [
            stage,
            Positioned(
              right: 16,
              bottom: 16,
              child: FloatingActionButton.extended(
                key: const Key('surface-bubble'),
                onPressed: () => ref.read(surfaceProvider.notifier).userSet(SurfaceState.docked),
                icon: const Icon(Icons.chevron_right),
                label: const Text('Motormind'),
              ),
            ),
          ],
        ),
        SurfaceState.docked => _Docked(content: stage),
        SurfaceState.fullscreen => const _Panel(key: Key('surface-fullscreen')),
      },
    );
  }
}

/// Marks the stage, so a run of dead taps can be placed: on the stage, or
/// in the Motormind panel.
final GlobalKey stageRegionKey = GlobalKey(debugLabel: 'stage-region');

/// Watches every tap on the screen without taking it (the gestures below
/// still get it) and tells Motormind when taps repeat in one place while
/// nothing on screen changes (see [TapJournal]).
class _TapWatch extends ConsumerStatefulWidget {
  const _TapWatch({required this.child});

  final Widget child;

  @override
  ConsumerState<_TapWatch> createState() => _TapWatchState();
}

class _TapWatchState extends ConsumerState<_TapWatch> {
  final _journal = TapJournal();
  final Map<int, Offset> _downs = {};

  /// A pointer that moved further than this between down and up was a
  /// scroll or a drag, not a tap.
  static const _tapSlop = 18.0;

  /// The tile's own "tapping that one" question is asked from the tap
  /// callback, which runs after this listener; waiting this long lets it
  /// win, and the general question then stands down.
  static const _yieldToTileQuestion = Duration(milliseconds: 60);

  /// What the screen shows, as a string that changes when anything a tap
  /// could have changed does.
  String _fingerprint() {
    final stage = ref.read(stageProvider);
    final chat = ref.read(chatServiceProvider);
    final search = ref.read(searchProvider);
    final signals = ref.read(listingSignalsProvider);
    return [
      stage.mode.name,
      stage.cards.length,
      stage.focus,
      chat.timeline.length,
      chat.busy,
      search.query.describe(),
      search.applying,
      ref.read(surfaceProvider).name,
      ref.read(bigPhotoProvider),
      ref.read(browserProvider).url,
      signals.viewed.length,
      signals.liked.length,
      signals.dismissed.length,
    ].join('|');
  }

  String _regionOf(Offset global) {
    final box = stageRegionKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      final local = box.globalToLocal(global);
      if (box.paintBounds.contains(local)) return 'the cards';
    }
    return 'the Motormind panel';
  }

  void _up(PointerUpEvent e) {
    final down = _downs.remove(e.pointer);
    if (down == null || (e.position - down).distance > _tapSlop) return;
    if (!_journal.tap(e.position, DateTime.now(), _fingerprint())) return;
    final region = _regionOf(e.position);
    logDev('dead taps: $region');
    Future<void>.delayed(_yieldToTileQuestion, () {
      if (mounted) ref.read(chatServiceProvider.notifier).noticeDeadTaps(region);
    });
  }

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (e) => _downs[e.pointer] = e.position,
    onPointerUp: _up,
    onPointerCancel: (e) => _downs.remove(e.pointer),
    child: widget.child,
  );
}

class _Docked extends ConsumerStatefulWidget {
  const _Docked({required this.content});

  final Widget content;

  @override
  ConsumerState<_Docked> createState() => _DockedState();
}

class _DockedState extends ConsumerState<_Docked> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The keyboard shows up as a bottom inset; the display decision wants to
  /// know, and the widget tree is where that is known.
  @override
  void didChangeMetrics() {
    final keyboardUp = View.of(context).viewInsets.bottom > 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(keyboardOpenProvider.notifier).set(keyboardUp);
    });
  }

  @override
  Widget build(BuildContext context) {
    final keyboardUp = MediaQuery.viewInsetsOf(context).bottom > 0;
    final split = keyboardUp ? StageSplit.typing : ref.watch(displayProvider).split;
    final stageFlex = AdvisorSurfaceHost.stageFlexFor(split);
    return Column(
      children: [
        Expanded(
          flex: stageFlex,
          child: ClipRect(child: widget.content),
        ),
        Expanded(
          flex: 100 - stageFlex,
          child: const _Panel(key: Key('surface-docked')),
        ),
      ],
    );
  }
}

/// The conversation panel with its header: the name, the display indicator
/// and the surface toggle.
class _Panel extends ConsumerWidget {
  const _Panel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final decision = ref.watch(displayProvider);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      child: ChatPanel(
        header: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(width: 16),
                Expanded(child: Text('Motormind', style: theme.textTheme.titleSmall)),
                _DisplayIndicator(decision: decision),
                const _SurfaceToggle(),
              ],
            ),
            if (decision.cue case final cue?)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Text(cue, key: const Key('display-cue'), style: theme.textTheme.labelSmall),
              ),
          ],
        ),
      ),
    );
  }
}

/// The display agent's indicator: a small fixed mark, never a row, because
/// the person only needs to know that the screen may change. The tooltip
/// says who decided and how long it took.
class _DisplayIndicator extends StatelessWidget {
  const _DisplayIndicator({required this.decision});

  final DisplayDecision decision;

  String get _tooltip {
    if (decision.thinking) return 'Motormind is arranging the screen';
    final took = decision.tookMs == null ? '' : ' in ${decision.tookMs} ms';
    return 'Screen arranged by ${decision.by.name}$took';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: _tooltip,
      child: SizedBox(
        key: const Key('display-indicator'),
        width: 12,
        height: 12,
        child: decision.thinking
            ? const CircularProgressIndicator(strokeWidth: 1.5)
            : Icon(
                Icons.circle,
                size: 8,
                color: decision.by == DecidedBy.model
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
      ),
    );
  }
}

/// The signature "</>" control: cycles collapsed, docked, fullscreen.
class _SurfaceToggle extends ConsumerWidget {
  const _SurfaceToggle();

  @override
  Widget build(BuildContext context, WidgetRef ref) => IconButton(
    key: const Key('surface-toggle'),
    tooltip: 'Expand or collapse Motormind',
    icon: const Icon(Icons.code),
    onPressed: ref.read(surfaceProvider.notifier).cycle,
  );
}
