import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/advisor/tap_journal.dart';

void main() {
  final t0 = DateTime(2026, 11, 1, 10);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  test('three taps in one place with nothing changing is a run, even slowly', () {
    final j = TapJournal();
    expect(j.tap(const Offset(100, 200), at(0), 's'), isFalse);
    expect(j.tap(const Offset(110, 205), at(20), 's'), isFalse);
    expect(j.tap(const Offset(95, 190), at(45), 's'), isTrue);
    // The run starts over afterwards.
    expect(j.tap(const Offset(100, 200), at(46), 's'), isFalse);
  });

  test('a change on screen, another place, or a long pause breaks the run', () {
    final changed = TapJournal()
      ..tap(const Offset(100, 200), at(0), 'a')
      ..tap(const Offset(100, 200), at(1), 'b');
    expect(changed.tap(const Offset(100, 200), at(2), 'b'), isFalse);

    final moved = TapJournal()
      ..tap(const Offset(100, 200), at(0), 's')
      ..tap(const Offset(100, 200), at(1), 's');
    expect(moved.tap(const Offset(300, 200), at(2), 's'), isFalse);

    final paused = TapJournal()
      ..tap(const Offset(100, 200), at(0), 's')
      ..tap(const Offset(100, 200), at(1), 's');
    expect(paused.tap(const Offset(100, 200), at(70), 's'), isFalse);
  });
}
