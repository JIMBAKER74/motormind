import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/log.dart';

/// What started a turn. The comparison the owner asked for (2026-10-22) is
/// between these: does a tapped choice answer faster than a typed sentence,
/// and what does a tile's "Monthly cost?" cost?
enum TurnTrigger {
  /// The person typed and sent.
  typed,

  /// The person tapped an option on a choice card (the opening modes, a
  /// dream-car kind, a model-offered choice).
  choice,

  /// The person tapped "Monthly cost?" on a listing tile.
  tileCost,

  /// The app noticed something (a second listing opened) and asked the
  /// model whether to show anything; no words from the person.
  signal,

  /// The same message again, after the window filled and the session was
  /// reopened.
  retry,
}

/// One turn, timed from the person's side of the screen: when it started,
/// when the first word appeared, when it ended, and what happened between.
/// Wall-clock milliseconds; the engine's own prefill and decode lines in
/// the log break the same turn down further.
class TurnStats {
  const TurnStats({
    required this.trigger,
    required this.detail,
    required this.startedAt,
    required this.totalMs,
    required this.promptChars,
    required this.outputPieces,
    required this.tools,
    required this.displayAgentOn,
    this.firstTextMs,
    this.failed = false,
  });

  final TurnTrigger trigger;

  /// Which choice or tile, as an id; never the person's words.
  final String detail;
  final DateTime startedAt;

  /// Milliseconds to the first piece of reply text; null when the reply had
  /// none (the app wrote the sentence, or the turn failed).
  final int? firstTextMs;

  /// Milliseconds from start to the end of the turn.
  final int totalMs;

  /// Characters sent to the model this turn: the message plus the context
  /// lines the app adds. About four characters to a token.
  final int promptChars;

  /// Streamed pieces of reply text; on this engine one piece is about one
  /// token.
  final int outputPieces;

  /// Tools the model called, each with the milliseconds into the turn at
  /// which it started.
  final List<(String, int)> tools;

  /// True when the second session (display agent) was switched on; its
  /// decisions replay the conversation and slow the next turn.
  final bool displayAgentOn;

  final bool failed;

  /// Output pieces per second after the first one, or null when there was
  /// not enough text to say.
  double? get piecesPerSecond {
    final first = firstTextMs;
    if (first == null || outputPieces < 2 || totalMs <= first) return null;
    return (outputPieces - 1) / ((totalMs - first) / 1000);
  }

  /// One line for the developer log and the Models screen.
  String describe() {
    final rate = piecesPerSecond;
    return [
      '${trigger.name}${detail.isEmpty ? '' : ':$detail'}',
      'first ${firstTextMs == null ? '-' : '${firstTextMs}ms'}',
      'total ${totalMs}ms',
      if (tools.isNotEmpty) 'tools ${tools.map((t) => '${t.$1}@${t.$2}ms').join(',')}',
      'out $outputPieces${rate == null ? '' : ' (${rate.toStringAsFixed(1)}/s)'}',
      'prompt ${promptChars}ch',
      if (displayAgentOn) 'display-agent on',
      if (failed) 'FAILED',
    ].join(' · ');
  }
}

/// This session's turns, newest first, at most [TurnStatsLog.keep].
final turnStatsProvider = NotifierProvider<TurnStatsLog, List<TurnStats>>(TurnStatsLog.new);

final class TurnStatsLog extends Notifier<List<TurnStats>> {
  /// Enough for a demo's worth of turns on one screen.
  static const keep = 40;

  @override
  List<TurnStats> build() => const [];

  void add(TurnStats s) {
    logDev('turn stats: ${s.describe()}');
    state = [s, ...state].take(keep).toList();
  }
}
