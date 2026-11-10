/// Where a component renders (design notes 5.6). The agents name these; the
/// app decides what each may hold.
enum Region {
  /// Inline in the conversation: interaction components and the filters
  /// card.
  conversation,

  /// The content area above the conversation: one card large, the rest as
  /// chips.
  stage,
}

/// A component's state as the agents are told it (design notes 5.3).
enum ComponentState {
  /// Shown in full: a live question, the filters card open.
  expanded,

  /// Reduced to a line or a chip: a stage card that is not the large one.
  summary,

  /// On screen in name only: stage cards while the web page is in view.
  hidden,

  /// The stage card shown large.
  focused;

  /// The one-character mark the record uses, explained once in
  /// [ContextRecorder.legend]: `*` shown large, `~` behind the web page.
  String get mark => switch (this) {
    focused => '*',
    hidden => '~',
    expanded || summary => '',
  };
}

/// One component on screen, as both agents and the log see it (DD-R37).
final class ActiveComponent {
  /// Creates an entry for the app's [id], showing registry [component] in
  /// [region] with [state]; [detail] adds ids and counts.
  const ActiveComponent({
    required this.id,
    required this.component,
    required this.region,
    required this.state,
    this.detail = '',
  });

  /// The app's own id ("c12"), which the model names in `present(target:)`.
  final String id;

  /// The registry id of what is shown.
  final String component;

  /// Where it is.
  final Region region;

  /// How it is shown.
  final ComponentState state;

  /// Result ids, listing ids, counts or a question's words; never a price,
  /// payment, income or rate (design notes 5.3, "names and counts").
  final String detail;

  /// The entry as one item of the record: `c12* vehicle_card r3 22 cars`.
  /// The region is the key it is listed under; the state is [ComponentState.mark].
  String describe() => '$id${state.mark} $component${detail.isEmpty ? '' : ' $detail'}';
}

/// What the app tells the interaction agent with a turn (design notes 5.3,
/// DD-R36): the screen's goal, the frame (how the person shops, the panel,
/// what the stage shows, the keyboard), the active list and what changed
/// since the model's last turn. The filters and listing signals travel in
/// lines of their own.
final class ContextRecord {
  /// Creates a record; [changed] lists what happened since the last turn,
  /// oldest first.
  const ContextRecord({
    required this.active,
    this.goal,
    this.mode,
    this.panel = 'docked',
    this.view = 'cards',
    this.keyboardUp = false,
    this.changed = const [],
  });

  /// What is being decided right now, naming ids where it can ("answer
  /// c2", "pick from c1"), or null when nothing is (design notes 5.7).
  final String? goal;

  /// How the person shops, in their words; null before they have said.
  final String? mode;

  /// The Motormind panel: collapsed, docked or fullscreen.
  final String panel;

  /// What the stage shows: cards or web.
  final String view;

  /// Whether the keyboard is up.
  final bool keyboardUp;

  /// The components on screen, newest first within each region.
  final List<ActiveComponent> active;

  /// What happened since the model's last turn, oldest first, in short
  /// phrases naming ids: `returned 40m`, `set aside c7`.
  final List<String> changed;
}

/// One serialized record and what it cost.
final class RecordText {
  /// Creates the outcome of [ContextRecorder.next].
  const RecordText({
    required this.text,
    required this.tokens,
    required this.fields,
    required this.cut,
  });

  /// The bracketed block for the model; empty when nothing changed.
  final String text;

  /// Estimated tokens of [text] ([ContextRecorder.charsPerToken]).
  final int tokens;

  /// The keys sent (goal, mode, panel, view, kb, conv, stage, new), for the
  /// log, which never carries the values.
  final List<String> fields;

  /// Items dropped to stay within the budget.
  final int cut;
}

/// Turns successive [ContextRecord]s into what the model is told, under the
/// record's rules (design notes 5.3): say what changed, not what the screen
/// is (each key travels only when its value changed; `new` always);
/// nothing when nothing changed; bounded, with the oldest items dropped
/// first and the cut marked.
///
/// The form is compact keys with a legend the model reads once in the
/// opening context ([legend]), which the runtime prefills a single time per
/// session; every turn then pays only for the short form. The owner's note
/// (QUESTIONS C28): what a person reads and what the model reads can differ,
/// as long as the model is told the mapping.
final class ContextRecorder {
  /// Creates a recorder with a budget of [budgetTokens].
  ContextRecorder({this.budgetTokens = defaultBudgetTokens});

  /// The interaction agent's budget per turn, DD-Q25's default. Unmeasured
  /// on a phone; the log carries each turn's estimate so it can be set from
  /// data.
  static const defaultBudgetTokens = 80;

  /// Characters per token for the estimate. Gemma's tokenizer is not
  /// reachable from Dart; four characters a token is the usual figure for
  /// English and errs high for the short words and ids the record holds.
  static const charsPerToken = 4;

  /// What the keys and marks mean, for the opening context. Paid once per
  /// session, so the per-turn record can be short.
  static const legend =
      'A [Screen ...] line is the app\'s note of the screen; only what changed is sent. '
      'goal: what is being decided now. mode: how the person shops. panel: Motormind\'s '
      'panel (collapsed, docked, fullscreen). view: the stage shows cards or the web page. '
      'kb: keyboard. conv: questions live in the conversation. stage: cards above it; * is '
      'the one shown large, ~ is behind the web page; a listings card holds L1 to Ln. new: '
      'what happened since your last turn. c12 is a card\'s id, the target of present.';

  /// Tokens the record may use.
  final int budgetTokens;

  final Map<String, String> _sent = {};

  /// Forgets what the model was told, for a new session.
  void reset() => _sent.clear();

  /// The block for [r]. Remembers what it sent, so the next call sends only
  /// what changed. [force] sends every key (the first turn of a session).
  RecordText next(ContextRecord r, {bool force = false}) {
    List<ActiveComponent> inRegion(Region g) => [...r.active.where((a) => a.region == g)];
    final conv = inRegion(Region.conversation);
    var stage = inRegion(Region.stage);
    final values = {
      'goal': r.goal ?? 'none',
      'mode': '"${r.mode ?? 'not said yet'}"',
      'panel': r.panel,
      'view': r.view,
      'kb': r.keyboardUp ? 'up' : 'down',
      'conv': _items(conv, conv.length),
      'stage': _items(stage, stage.length),
    };
    final keys = [
      for (final e in values.entries)
        if (force || _sent[e.key] != e.value) e.key,
    ];
    _sent.addAll(values);

    var changed = [...r.changed];
    var cut = 0;
    String build() {
      final parts = [
        for (final k in keys)
          '$k=${k == 'stage' ? _items(stage, inRegion(Region.stage).length) : values[k]}',
        if (changed.isNotEmpty)
          'new=${changed.length < r.changed.length ? '(earlier cut) ' : ''}${changed.join(', ')}',
      ];
      return parts.isEmpty ? '' : '[Screen ${parts.join('; ')}]';
    }

    var text = build();
    // Oldest changes go first, then the stage's oldest cards, never below
    // one item of each: a record that says nothing is worse than one over
    // budget.
    while (_tokens(text) > budgetTokens &&
        (changed.length > 1 || (keys.contains('stage') && stage.length > 1))) {
      if (changed.length > 1) {
        changed = changed.sublist(1);
      } else {
        stage = stage.sublist(0, stage.length - 1);
      }
      cut++;
      text = build();
    }
    return RecordText(
      text: text,
      tokens: _tokens(text),
      fields: [...keys, if (r.changed.isNotEmpty) 'new'],
      cut: cut,
    );
  }

  static String _items(List<ActiveComponent> kept, int total) {
    if (total == 0) return 'none';
    final more = total - kept.length;
    return '${kept.map((a) => a.describe()).join(' | ')}${more > 0 ? ' | +$more more' : ''}';
  }

  static int _tokens(String s) => (s.length / charsPerToken).ceil();

  /// Estimated tokens of any context text, by the same rule as the record.
  static int estimateTokens(String s) => _tokens(s);
}
