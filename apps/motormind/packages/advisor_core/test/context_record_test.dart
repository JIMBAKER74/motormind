import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

const _listings = ActiveComponent(
  id: 'c4',
  component: 'vehicle_card',
  region: Region.stage,
  state: ComponentState.focused,
  detail: 'r3, 22 cars',
);

ContextRecord _record({
  List<ActiveComponent> active = const [_listings],
  List<String> changed = const [],
  String? goal = 'choosing which of 22 cars to look at',
  String frame = 'the person is just looking; docked, stage cards; keyboard down',
}) => ContextRecord(goal: goal, frame: frame, active: active, changed: changed);

void main() {
  test('the first record sends every field; an unchanged one sends nothing', () {
    final recorder = ContextRecorder();
    final first = recorder.next(_record());
    expect(first.text, startsWith('[Screen: goal: choosing which of 22 cars'));
    expect(first.text, contains('active: c4 vehicle_card (r3, 22 cars) stage focused'));
    expect(first.fields, ['goal', 'frame', 'active']);
    final again = recorder.next(_record());
    expect(again.text, isEmpty);
    expect(again.tokens, 0);
  });

  test('only what changed travels; changes always do', () {
    final recorder = ContextRecorder()..next(_record());
    final r = recorder.next(_record(changed: ['returned after 40m']));
    expect(r.text, '[Screen: changed: returned after 40m.]');
    expect(r.fields, ['changed']);
    final compare = recorder.next(
      _record(
        goal: 'comparing L1 and L2',
        active: [
          const ActiveComponent(
            id: 'c7',
            component: 'vehicle_compare',
            region: Region.stage,
            state: ComponentState.focused,
            detail: 'L1, L2',
          ),
          _listings,
        ],
      ),
    );
    expect(compare.fields, ['goal', 'active']);
    expect(compare.text, isNot(contains('keyboard')));
  });

  test('force sends everything again, as for a new session', () {
    final recorder = ContextRecorder()..next(_record());
    expect(recorder.next(_record(), force: true).fields, ['goal', 'frame', 'active']);
    recorder.reset();
    expect(recorder.next(_record()).fields, ['goal', 'frame', 'active']);
  });

  test('over budget, the oldest changes go first and the cut is marked', () {
    final recorder = ContextRecorder(budgetTokens: 40);
    final r = recorder.next(
      _record(
        changed: [
          'tapped the cards 3 times and nothing changed',
          'asked for: bigger',
          'returned after 40m',
        ],
      ),
    );
    expect(r.cut, greaterThan(0));
    expect(r.text, contains('(earlier cut) '));
    expect(r.text, contains('returned after 40m'));
    expect(r.text, isNot(contains('tapped the cards')));
  });

  test('the active list loses its oldest cards next, and says how many', () {
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
    final r = ContextRecorder(budgetTokens: 60).next(_record(active: many));
    expect(r.text, contains('c1 payment_summary'));
    expect(r.text, isNot(contains('c6 ')));
    expect(r.text, matches(RegExp(r'\+\d more')));
    expect(r.tokens, lessThanOrEqualTo(60));
  });

  test('never below one item of each, even over budget', () {
    final r = ContextRecorder(budgetTokens: 1).next(_record(changed: ['returned after 2h']));
    expect(r.text, contains('c4 vehicle_card'));
    expect(r.text, contains('returned after 2h'));
  });

  test('the token estimate is four characters a token, rounded up', () {
    expect(ContextRecorder.estimateTokens(''), 0);
    expect(ContextRecorder.estimateTokens('abcde'), 2);
  });
}
