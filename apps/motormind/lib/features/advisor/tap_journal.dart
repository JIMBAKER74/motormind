import 'dart:ui' show Offset;

/// Taps kept "for a while" (the owner's words, QUESTIONS Q82) to tell a
/// person navigating from a person repeating themselves because the screen
/// is not doing what they want. A repeated gesture that does not match what
/// the element is for is the clearest signal a screen gets; a traditional
/// design process learns it from analytics and a release cycle, and here
/// the app answers it in the session (design notes, principle 18, DD-R42).
///
/// A run is [threshold] taps within [window] of each other, each within
/// [radius] of the first, during which the app's visible state did not
/// change (the caller supplies a fingerprint of it). Not necessarily quick:
/// someone who does not know what to expect taps slowly.
final class TapJournal {
  /// Taps further apart than this start a new run.
  static const window = Duration(seconds: 60);

  /// How far apart, in logical pixels, taps may be and still be "the same
  /// place": about a fingertip and a half.
  static const radius = 36.0;

  /// Taps in a run that mean the person wants something else.
  static const threshold = 3;

  Offset? _first;
  DateTime? _last;
  String? _state;
  int _count = 0;

  /// Records a tap at [at] (logical pixels) at [now], with [state] a
  /// fingerprint of what the screen showed. True when the run reached
  /// [threshold]; the run then starts over.
  bool tap(Offset at, DateTime now, String state) {
    final first = _first;
    final last = _last;
    final sameRun =
        first != null &&
        last != null &&
        now.difference(last) <= window &&
        (at - first).distance <= radius &&
        state == _state;
    if (!sameRun) {
      _first = at;
      _state = state;
      _count = 0;
    }
    _count++;
    _last = now;
    if (_count < threshold) return false;
    _first = null;
    _count = 0;
    return true;
  }
}
