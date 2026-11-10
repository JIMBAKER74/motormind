import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

const _question = ActiveComponent(
  id: 'c2',
  component: 'choice',
  region: Region.conversation,
  state: ComponentState.expanded,
  detail: '"How are you shopping today?"',
);

const _listings = ActiveComponent(
  id: 'c1',
  component: 'vehicle_card',
  region: Region.stage,
  state: ComponentState.focused,
  detail: 'r1 22 cars',
);

ContextRecord _record({
  List<ActiveComponent> active = const [_question, _listings],
  List<String> changed = const [],
  String? goal = 'answer c2',
  String? mode,
  String view = 'cards',
}) => ContextRecord(goal: goal, mode: mode, view: view, active: active, changed: changed);

void main() {
  test('the first record sends every key; an unchanged one sends nothing', () {
    final recorder = ContextRecorder();
    final first = recorder.next(_record());
    expect(
      first.text,
      '[Screen goal=answer c2; mode="not said yet"; panel=docked; view=cards; kb=down; '
      'conv=c2 choice "How are you shopping today?"; stage=c1* vehicle_card r1 22 cars]',
    );
    expect(first.fields, ['goal', 'mode', 'panel', 'view', 'kb', 'conv', 'stage']);
    final again = recorder.next(_record());
    expect(again.text, isEmpty);
    expect(again.tokens, 0);
  });

  test('the compact form costs well under the worded form it replaced', () {
    // The same screen as the first record, in the wording sent until
    // 2026-11-08 (estimated at the same four characters a token).
    const worded =
        '[Screen: goal: answering "How are you shopping today?"; the person is not yet saying how '
        'they shop; docked, stage cards; keyboard down; active: c2 choice ("How are you '
        'shopping today?") conversation expanded; c1 vehicle_card (r1, 22 cars, L1-L22) stage '
        'focused.]';
    final compact = ContextRecorder().next(_record()).tokens;
    expect(compact, lessThan(ContextRecorder.estimateTokens(worded) * 0.7));
  });

  test('only the keys that changed travel; changes always do', () {
    final recorder = ContextRecorder()..next(_record());
    final r = recorder.next(_record(changed: ['returned 40m']));
    expect(r.text, '[Screen new=returned 40m]');
    expect(r.fields, ['new']);
    final answered = recorder.next(
      _record(goal: 'pick from c1', mode: 'just looking around', active: [_listings]),
    );
    expect(answered.fields, ['goal', 'mode', 'conv']);
    expect(answered.text, contains('conv=none'));
    expect(answered.text, contains('mode="just looking around"'));
  });

  test('marks: * shown large, ~ behind the web page, nothing for a chip', () {
    const chip = ActiveComponent(
      id: 'c5',
      component: 'vehicle_compare',
      region: Region.stage,
      state: ComponentState.summary,
      detail: 'L1 L2',
    );
    const hidden = ActiveComponent(
      id: 'c1',
      component: 'vehicle_card',
      region: Region.stage,
      state: ComponentState.hidden,
    );
    expect(chip.describe(), 'c5 vehicle_compare L1 L2');
    expect(hidden.describe(), 'c1~ vehicle_card');
    expect(_listings.describe(), 'c1* vehicle_card r1 22 cars');
  });

  test('the legend explains every key and mark the record uses', () {
    for (final k in ['goal', 'mode', 'panel', 'view', 'kb', 'conv', 'stage', 'new', '*', '~']) {
      expect(ContextRecorder.legend, contains(k));
    }
  });

  test('force sends everything again, as for a new session', () {
    final recorder = ContextRecorder()..next(_record());
    expect(recorder.next(_record(), force: true).fields, hasLength(7));
    recorder.reset();
    expect(recorder.next(_record()).fields, hasLength(7));
  });

  test('over budget, the oldest changes go first and the cut is marked', () {
    final recorder = ContextRecorder(budgetTokens: 40);
    final r = recorder.next(
      _record(
        changed: ['tapped the cards x3, nothing changed', 'asked for: bigger', 'returned 40m'],
      ),
    );
    expect(r.cut, greaterThan(0));
    expect(r.text, contains('(earlier cut) '));
    expect(r.text, contains('returned 40m'));
    expect(r.text, isNot(contains('tapped the cards')));
  });

  test('the stage loses its oldest cards next, and says how many', () {
    final many = [
      for (var i = 1; i <= 6; i++)
        ActiveComponent(
          id: 'c$i',
          component: 'payment_summary',
          region: Region.stage,
          state: i == 1 ? ComponentState.focused : ComponentState.summary,
          detail: 'r$i',
        ),
    ];
    final r = ContextRecorder(budgetTokens: 45).next(_record(active: many));
    expect(r.text, contains('c1* payment_summary'));
    expect(r.text, isNot(contains('c6 ')));
    expect(r.text, matches(RegExp(r'\+\d more')));
    expect(r.tokens, lessThanOrEqualTo(45));
  });

  test('never below one item of each, even over budget', () {
    final r = ContextRecorder(budgetTokens: 1).next(_record(changed: ['returned 2h']));
    expect(r.text, contains('c1* vehicle_card'));
    expect(r.text, contains('returned 2h'));
  });

  test('the token estimate is four characters a token, rounded up', () {
    expect(ContextRecorder.estimateTokens(''), 0);
    expect(ContextRecorder.estimateTokens('abcde'), 2);
  });
}
