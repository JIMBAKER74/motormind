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
  focused,
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

  /// The entry as one item of the record: `c12 vehicle_card (r3, 22 cars)
  /// stage focused`.
  String describe() =>
      '$id $component${detail.isEmpty ? '' : ' ($detail)'} ${region.name} ${state.name}';
}

/// What the app tells the interaction agent with a turn (design notes 5.3,
/// DD-R36): the screen's goal, the frame (how the person shops, the surface,
/// the keyboard), the active list and what changed since the model's last
/// turn. The filters and listing signals travel in lines of their own.
final class ContextRecord {
  /// Creates a record; [changed] lists what happened since the last turn,
  /// oldest first.
  const ContextRecord({
    required this.frame,
    required this.active,
    this.goal,
    this.changed = const [],
  });

  /// What is being decided right now, one line (design notes 5.7), or null
  /// when nothing is.
  final String? goal;

  /// How the person shops, the surface and the keyboard, in words.
  final String frame;

  /// The components on screen, newest first within each region.
  final List<ActiveComponent> active;

  /// What happened since the model's last turn, oldest first: taps, a return
  /// from the background, the person's own changes to the screen.
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

  /// The names of the fields sent (goal, frame, active, changed), for the
  /// log, which never carries the values.
  final List<String> fields;

  /// Items dropped to stay within the budget.
  final int cut;
}

/// Turns successive [ContextRecord]s into what the model is told, under the
/// record's rules (design notes 5.3): say what changed, not what the screen
/// is (the goal, the frame and the active list travel only when they
/// changed; `changed` always); nothing when nothing changed; bounded, with
/// the oldest items dropped first and the cut marked.
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

  /// Tokens the record may use.
  final int budgetTokens;

  String? _goal;
  String? _frame;
  String? _shape;

  /// Forgets what the model was told, for a new session.
  void reset() {
    _goal = null;
    _frame = null;
    _shape = null;
  }

  /// The block for [r]. Remembers what it sent, so the next call sends only
  /// what changed. [force] sends every field (the first turn of a session).
  RecordText next(ContextRecord r, {bool force = false}) {
    final goal = r.goal ?? 'nothing in particular';
    final shape = r.active.map((a) => a.describe()).join('; ');
    final sendGoal = force || goal != _goal;
    final sendFrame = force || r.frame != _frame;
    final sendActive = force || shape != _shape;
    _goal = goal;
    _frame = r.frame;
    _shape = shape;

    var active = [...r.active];
    var changed = [...r.changed];
    var cut = 0;
    String build() {
      final parts = [
        if (sendGoal) 'goal: $goal',
        if (sendFrame) r.frame,
        if (sendActive) 'active: ${active.isEmpty ? 'nothing' : _items(active, r.active.length)}',
        if (changed.isNotEmpty)
          'changed: ${changed.length < r.changed.length ? '(earlier cut) ' : ''}'
              '${changed.join('; ')}',
      ];
      return parts.isEmpty ? '' : '[Screen: ${parts.join('; ')}.]';
    }

    var text = build();
    // Oldest changes go first, then the active list from its end (the
    // oldest cards), never below one item of each: a record that says
    // nothing is worse than one over budget.
    while (_tokens(text) > budgetTokens && (changed.length > 1 || active.length > 1)) {
      if (changed.length > 1) {
        changed = changed.sublist(1);
      } else {
        active = active.sublist(0, active.length - 1);
      }
      cut++;
      text = build();
    }
    return RecordText(
      text: text,
      tokens: _tokens(text),
      fields: [
        if (sendGoal) 'goal',
        if (sendFrame) 'frame',
        if (sendActive) 'active',
        if (r.changed.isNotEmpty) 'changed',
      ],
      cut: cut,
    );
  }

  static String _items(List<ActiveComponent> kept, int total) {
    final more = total - kept.length;
    return '${kept.map((a) => a.describe()).join('; ')}${more > 0 ? '; +$more more' : ''}';
  }

  static int _tokens(String s) => (s.length / charsPerToken).ceil();

  /// Estimated tokens of any context text, by the same rule as the record.
  static int estimateTokens(String s) => _tokens(s);
}
