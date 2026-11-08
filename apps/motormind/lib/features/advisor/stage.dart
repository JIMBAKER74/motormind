import 'package:advisor_core/advisor_core.dart' show ArrangeAction, ArrangeTarget;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat/chat_state.dart';

/// What the stage shows: the web pane or the presented cards.
enum StageMode {
  /// The curated site, the source of what the cards show.
  web,

  /// The cards the model or the app presented; the primary surface.
  cards,
}

/// The content area above the conversation.
class StageState {
  const StageState({
    this.mode = StageMode.web,
    this.cards = const [],
    this.focus = 0,
    this.userSet = false,
  });

  final StageMode mode;

  /// True when the person flipped Web/Cards by hand (or the app asked for
  /// the page to be seen); the display decision respects it until the next
  /// presented card.
  final bool userSet;

  /// Presented cards, newest first. Only [focus] is shown large; the rest are
  /// chips (no stacking: one card large at a time).
  final List<ShownComponent> cards;

  /// Index into [cards] of the one shown large; clamped on read.
  final int focus;

  ShownComponent? get focused => cards.isEmpty ? null : cards[focus.clamp(0, cards.length - 1)];

  StageState copyWith({StageMode? mode, List<ShownComponent>? cards, int? focus, bool? userSet}) =>
      StageState(
        mode: mode ?? this.mode,
        cards: cards ?? this.cards,
        focus: focus ?? this.focus,
        userSet: userSet ?? this.userSet,
      );
}

/// The stage: either the web pane or the cards the model (or the app) has
/// presented. Presenting a card brings the cards forward; opening a page
/// brings the web forward; the person can flip between them any time.
final stageProvider = NotifierProvider<StageNotifier, StageState>(StageNotifier.new);

final class StageNotifier extends Notifier<StageState> {
  @override
  StageState build() => const StageState();

  /// What the person did to the stage by hand since the model's last turn,
  /// for the `changed` field of the context record (design notes 5.3).
  final List<String> _byPerson = [];

  /// Returns and forgets [_byPerson].
  List<String> takePersonChanges() {
    final out = [..._byPerson];
    _byPerson.clear();
    return out;
  }

  /// Adds a component at the front. [bringForward] flips to Cards; the live
  /// search leaves the web page in view and only badges the Cards tab.
  void show(ShownComponent c, {bool bringForward = true}) {
    // A newer card for the same result replaces the older one (the model's
    // breakdown over the app's automatic summary), except a compare, which
    // is a second view of the listings and sits beside them: it replaced
    // the listings card on the emulator (2026-11-02).
    final id = c.result?.id;
    bool isCompare(ShownComponent s) => s.request.component.id == 'vehicle_compare';
    final kept = id == null
        ? state.cards
        : state.cards.where((s) => s.result?.id != id || isCompare(s) != isCompare(c)).toList();
    state = state.copyWith(
      mode: bringForward ? StageMode.cards : state.mode,
      cards: [c, ...kept],
      focus: 0,
      userSet: false,
    );
  }

  /// Drops the cards matching [test] and focuses the newest remaining one.
  void removeWhere(bool Function(ShownComponent) test) =>
      state = state.copyWith(cards: state.cards.where((s) => !test(s)).toList(), focus: 0);

  /// Shows card [i] large (from the chip strip).
  void focusCard(int i) {
    assert(i >= 0 && i < state.cards.length, 'card index $i out of range');
    _byPerson.add('the person opened c${state.cards[i].id}');
    state = state.copyWith(focus: i.clamp(0, state.cards.length - 1), mode: StageMode.cards);
  }

  /// The model's change to a card already on the stage: the card with the
  /// app's id in [target] ("c12"), else the newest card showing its
  /// component (from its result, when given), is shown large or taken off.
  /// False when there is no such card. Focusing brings the cards forward, as
  /// the person asked for that card; closing the last card leaves the page
  /// in view.
  bool arrange(ArrangeAction action, ArrangeTarget target) {
    final id = int.tryParse(target.id?.replaceFirst(RegExp('^c', caseSensitive: false), '') ?? '');
    final i = state.cards.indexWhere(
      (c) => target.id != null
          ? c.id == id
          : c.request.component.id == target.componentId &&
                (target.resultId == null || c.result?.id == target.resultId),
    );
    if (i < 0) return false;
    switch (action) {
      case ArrangeAction.focus:
        state = state.copyWith(focus: i, mode: StageMode.cards, userSet: false);
      case ArrangeAction.close:
        final left = [...state.cards]..removeAt(i);
        state = state.copyWith(
          cards: left,
          focus: 0,
          mode: left.isEmpty ? StageMode.web : state.mode,
        );
    }
    return true;
  }

  /// The page needs to be seen (a read in progress, a human check, an
  /// "open on site" tap): this holds until the next presented card.
  void showWeb() => state = state.copyWith(mode: StageMode.web, userSet: true);

  /// From the person's own Web/Cards control.
  void setMode(StageMode m) {
    if (m != state.mode) _byPerson.add('the person switched the stage to ${m.name}');
    state = state.copyWith(mode: m, userSet: true);
  }

  /// From the display decision; never overrides a manual flip.
  void applyDecision(StageMode m) {
    if (!state.userSet && state.mode != m && (m == StageMode.web || state.cards.isNotEmpty)) {
      state = state.copyWith(mode: m);
    }
  }
}
