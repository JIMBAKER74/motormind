import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/advisor/advisor_surface.dart';
import 'package:motormind/features/advisor/display_agent.dart';
import 'package:motormind/features/advisor/stage.dart';
import 'package:motormind/features/advisor/tap_journal.dart';
import 'package:motormind/features/browser/browser_service.dart';
import 'package:motormind/features/chat/chat_panel.dart';
import 'package:motormind/features/chat/chat_service.dart';
import 'package:motormind/features/chat/chat_strings.dart';
import 'package:motormind/features/chat/starters.dart';
import 'package:motormind/features/chat/turn_stats.dart';
import 'package:motormind/features/listings/listing_signals.dart';
import 'package:motormind/features/search/search_service.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

import 'harness.dart';

/// A model stand-in. Each branch is one behavior the tests need: a payment
/// turn that calls the real tool and narrates the computed figure (so the
/// guard passes), a plain reply, a choice prompt, and scripted misbehavior.
class ScriptedDriver implements ChatDriver {
  final List<String> systemInstructions = [];
  final List<String> prompts = [];
  final List<String> warmUps = [];

  /// Holds the warm-up open until completed, like a slow prefill.
  Completer<void>? warmGate;

  /// How many "long story" turns fail with the engine's full-window error
  /// before one succeeds.
  int overflowsLeft = 0;

  /// Completes each time a turn's stream closes, so tests can wait for the
  /// turn instead of sleeping.
  Completer<void> _idle = Completer<void>();
  Future<void> get idle => _idle.future;

  /// Completes when [send] is entered and is renewed when that turn's stream
  /// closes, so a test can act in the middle of a turn without a wall-clock
  /// sleep.
  Completer<void> _started = Completer<void>();
  Future<void> get started => _started.future;

  /// Completed by [cancel]; the hanging branch waits on it, so an interrupt
  /// or the watchdog ends the turn the way the real engine would.
  Completer<void> _cancelled = Completer<void>();

  @override
  Stream<DriverChunk> send(String userText, {required ToolCallHandler onToolCall}) {
    prompts.add(userText);
    _idle = Completer<void>();
    _cancelled = Completer<void>();
    if (!_started.isCompleted) _started.complete();
    return _reply(userText, onToolCall).asBroadcastStream()
      ..listen(null, onDone: _finish, onError: (_) => _finish());
  }

  /// Called once per turn; a stream that errors calls both onError and
  /// onDone, so the second call is a no-op.
  void _finish() {
    if (_idle.isCompleted) return;
    _idle.complete();
    _started = Completer<void>();
  }

  Stream<DriverChunk> _reply(String userText, ToolCallHandler onToolCall) async* {
    final opened = RegExp(r'opened two listings from (\S+): (L\d+) .*; (L\d+) ')
        .firstMatch(userText);
    if (userText.endsWith("I'm buying now and want to work through the numbers.")) {
      // What Gemma 4 E2B did on the emulator: record the mode, say nothing.
      await onToolCall('update_profile', {'shopping_mode': 'buying'});
    } else if (opened != null) {
      // What a model that takes the cue does: show the two side by side.
      await onToolCall('present', {
        'component': 'vehicle_compare',
        'result_id': opened.group(1),
        // Top level, as the tool declares it and as Gemma sends it.
        'ids': [opened.group(2), opened.group(3)],
      });
      yield const DriverText('Here they are side by side.');
    } else if (userText.endsWith('back to the list')) {
      // A card already on screen, focused rather than presented again.
      await onToolCall('present', {'component': 'vehicle_card', 'action': 'focus'});
      yield const DriverText('Here is the list again.');
    } else if (RegExp(r'focus (c\d+)$').firstMatch(userText) case final m?) {
      await onToolCall('present', {'action': 'focus', 'target': m.group(1)});
      yield const DriverText('There.');
    } else if (RegExp(r'close (c\d+)$').firstMatch(userText) case final m?) {
      await onToolCall('present', {'action': 'close', 'target': m.group(1)});
      yield const DriverText('Done.');
    } else if (userText.endsWith('close the comparison')) {
      await onToolCall('present', {'component': 'vehicle_compare', 'action': 'close'});
      await onToolCall('present', {'component': 'vehicle_compare', 'action': 'close'});
      yield const DriverText('Closed.');
    } else if (userText.contains('long story')) {
      if (overflowsLeft > 0) {
        overflowsLeft--;
        throw Exception(
          'Stream error: INVALID_ARGUMENT: Input token ids are too long. '
          'Exceeding the maximum number of tokens allowed: 2755 >= 2048',
        );
      }
      yield const DriverText('Here is the short version.');
    } else if (userText.contains('just looking') || userText.contains('sports car')) {
      yield const DriverText('Take a look around; tap a filter or tell me more.');
    } else if (userText.contains('450')) {
      final r = await onToolCall('estimate_payment', {
        'price': 22000,
        'term_months': 60,
        'credit_band': 'good',
        'down_payment': 1000,
      });
      await onToolCall('present', {
        'component': 'payment_summary',
        'result_id': r['result_id'],
        'highlights': ['monthlyPayment'],
      });
      final p = ((r['outputs'] as Map)['monthlyPayment'] as num).toStringAsFixed(2);
      yield DriverText('That comes to \$$p a month over 60 months.');
    } else if (userText.contains('invent a number')) {
      yield const DriverText('You would pay about \$999 a month for that.');
    } else if (userText.contains('sell me')) {
      yield const DriverText('Act now, this deal will not last and you must buy today!');
    } else if (userText.contains('never answer')) {
      await _cancelled.future; // hangs until cancelled
    } else {
      await onToolCall('present', {
        'component': 'choice',
        'props': {
          'question': 'How are you shopping today?',
          'options': [
            {'id': 'browsing', 'label': 'Just looking'},
            {'id': 'buying', 'label': 'Buying now'},
          ],
        },
      });
      yield const DriverText('Happy to help.');
    }
  }

  @override
  Future<void> warmUp(String text) async {
    warmUps.add(text);
    await warmGate?.future;
  }

  @override
  Future<void> cancel() async {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  @override
  Future<void> close() async {}
}

/// Two listings, so client-side filtering has something to filter. The URL
/// is ignored on purpose: the fake stands in for whatever page the search
/// opened, and the test asserts the app's own filtering. A null [url] (a
/// `read_page` of whatever is open) reads as the default site's results.
Future<PageExtract> fakeReader({String? url}) async {
  final now = DateTime(2026, 10, 6);
  url ??= CuratedSites.defaultSite.home;
  return PageExtract(
    url: url,
    title: 'Fake results',
    text: '',
    listings: [
      VehicleListing(
        id: 'f1',
        title: '2021 Honda CR-V EX',
        sourceUrl: url,
        readAt: now,
        price: 27995,
        mileage: 45000,
        year: 2021,
        make: 'Honda',
        imageUrl: 'https://img.example.com/crv.jpg',
      ),
      VehicleListing(
        id: 'f2',
        title: '2023 BMW X3',
        sourceUrl: url,
        readAt: now,
        price: 41000,
        mileage: 20000,
        year: 2023,
        make: 'BMW',
      ),
    ],
  );
}

final _crvKey = ListingSignalsNotifier.keyFor(
  VehicleListing(
    id: 'f1',
    title: '2021 Honda CR-V EX',
    sourceUrl: '',
    readAt: DateTime(2026, 10, 6),
    price: 27995,
  ),
);

typedef Started = ({ScriptedDriver driver, ProviderContainer container});

/// Pumps the app at phone size, opens Motormind (docked, or fullscreen),
/// and starts the conversation with the scripted driver.
/// True when the web pane is parked (one pixel high) behind the cards: it
/// stays mounted so the page the person browsed is never reloaded.
bool _paneParked(WidgetTester tester) =>
    tester.getSize(find.byKey(const Key('web-pane-slot'))).height <= 1;

Future<Started> _start(
  WidgetTester tester, {
  bool fullscreen = true,
  Duration? idleLimit,
  Completer<void>? warmGate,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final driver = ScriptedDriver()..warmGate = warmGate;
  await tester.pumpWidget(
    await motormindApp(
      acknowledgedVersion: Disclosures.gateVersion,
      pageReader: fakeReader,
      overrides: [
        turnIdleLimitProvider.overrideWithValue(idleLimit),
        searchDebounceProvider.overrideWithValue(Duration.zero),
        chatDriverFactoryProvider.overrideWithValue((instruction) async {
          driver.systemInstructions.add(instruction);
          return driver;
        }),
      ],
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('surface-bubble')));
  await tester.pumpAndSettle();
  if (fullscreen) {
    await tester.tap(find.byKey(const Key('surface-toggle'))); // docked -> fullscreen
    await tester.pumpAndSettle();
  }
  // start() loads prompt assets (real async I/O), which pumpAndSettle cannot
  // wait for; the same goes for every scripted turn below.
  final container = containerOf(tester);
  await tester.runAsync(() => container.read(chatServiceProvider.notifier).start());
  await tester.pumpAndSettle();
  final state = container.read(chatServiceProvider);
  expect(state.ready, isTrue, reason: state.error);
  return (driver: driver, container: container);
}

/// Sends through the service and waits for the whole turn to finish: the
/// driver's stream closing, then the pipeline's guard and present steps.
Future<void> _turn(WidgetTester tester, Started s, Future<void> Function() act) async {
  await tester.runAsync(() async {
    await act();
    await s.driver.idle;
    await _untilIdle(s.container);
  });
  await tester.pumpAndSettle();
}

/// Resolves once the service reports the turn over (`busy` false).
Future<void> _untilIdle(ProviderContainer container) {
  if (!container.read(chatServiceProvider).busy) return Future.value();
  final done = Completer<void>();
  late final ProviderSubscription<ChatState> sub;
  sub = container.listen(chatServiceProvider, (_, next) {
    if (!next.busy && !done.isCompleted) {
      done.complete();
      sub.close();
    }
  });
  return done.future;
}

/// The search note the transcript should carry for the current search.
String _searchNoteNow(ProviderContainer container) {
  final s = container.read(searchProvider);
  return ChatStrings.searchNote(s.query.describe(), s.siteName, s.lastCount!);
}

Future<void> _chooseMode(WidgetTester tester, Started s, String mode) =>
    _turn(tester, s, () => tester.tap(find.byKey(Key('choice-mode-$mode'))));

Future<void> _tapFilter(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

String _hintOf(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('chat-input'))).decoration!.hintText!;

void main() {
  group('payment card', () {
    testWidgets('a payment question shows the card with the computed number', (tester) async {
      final s = await _start(tester);
      expect(s.driver.systemInstructions.single, contains('payment_summary'));
      // The app opens with the shopping-mode choice before any model turn.
      expect(find.byKey(const Key('choice-mode-practical')), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('chat-input')),
        'I can do 450 a month on a 22000 car with 1000 down',
      );
      await _turn(tester, s, () => tester.tap(find.byKey(const Key('chat-send'))));

      expect(find.byKey(const Key('card-payment_summary')), findsOneWidget);
      // Cards sit above the narration that comments on them.
      final cardY = tester.getTopLeft(find.byKey(const Key('card-payment_summary'))).dy;
      final replyY = tester.getTopLeft(find.textContaining('a month over 60 months')).dy;
      expect(cardY, lessThan(replyY));
      final expected = monthlyPayment(
        principal: 20000,
        apr: defaultAprTable.aprFor(CreditBand.good, isNew: false),
        termMonths: 60,
      );
      final shown = tester.widget<Text>(find.byKey(const Key('out-monthlyPayment'))).data!;
      expect(shown, contains(expected.toStringAsFixed(2).split('.').last));
      expect(find.byKey(const Key('guard-note')), findsNothing);
      expect(find.byKey(const Key('policy-banner')), findsNothing);
    });

    testWidgets('while docked, a presented card lands on the stage above the conversation', (
      tester,
    ) async {
      final s = await _start(tester, fullscreen: false);
      // Cards first: the site's first page was read at launch and its
      // listings are on the stage before anything was asked (DD-Q21).
      expect(find.byKey(const Key('listing-2021 Honda CR-V EX|27995')), findsOneWidget);
      expect(_paneParked(tester), isTrue);
      await _chooseMode(tester, s, 'practical');
      // The live filters and the numbers form join the conversation (checked
      // on the timeline: the docked list is lazy and short once the stage
      // holds listings); the stage keeps the listings.
      final chatList = find.byKey(const Key('chat-list'));
      final components = s.container
          .read(chatServiceProvider)
          .timeline
          .whereType<ComponentEntry>()
          .map((e) => e.shown.request.component.id)
          .toList();
      expect(components, containsAll(['search_filters', 'input_form']));
      expect(find.byKey(const Key('listing-2021 Honda CR-V EX|27995')), findsOneWidget);
      await _turn(
        tester,
        s,
        () => s.container
            .read(chatServiceProvider.notifier)
            .send('I can do 450 a month on a 22000 car with 1000 down'),
      );
      // The computed card is focused on the stage, not in the conversation.
      final stage = find.byKey(const Key('stage'));
      expect(
        find.descendant(of: stage, matching: find.byKey(const Key('card-payment_summary'))),
        findsOneWidget,
      );
      expect(_paneParked(tester), isTrue);
      expect(
        find.descendant(of: chatList, matching: find.byKey(const Key('card-payment_summary'))),
        findsNothing,
      );
    });
  });

  group('prompts and the escape', () {
    testWidgets('a mode chosen and answered with silence gets a sentence for that mode', (
      tester,
    ) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'buying');
      final replies = s.container
          .read(chatServiceProvider)
          .messages
          .where((m) => m.role == MessageRole.motormind);
      expect(replies.last.text, ChatStrings.afterMode(ShoppingMode.buying));
    });

    testWidgets('the model is told what is on screen, and only when it changed', (tester) async {
      final s = await _start(tester, fullscreen: false);
      // Turns whose replies are text only, so nothing on screen changes.
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('just looking around'),
      );
      // The warm-up carried the first screen line.
      final first = s.driver.warmUps.single;
      expect(s.driver.prompts.last, isNot(contains('[Screen ')));
      // The record (design notes 5.3) in its compact form: the goal names
      // the live question by id; the active list is by region, with * for
      // the card shown large.
      expect(
        first,
        matches(
          RegExp(
            r'\[Screen goal=answer c\d+; mode="not said yet"; panel=docked; view=cards; kb=down; ',
          ),
        ),
      );
      expect(first, matches(RegExp(r'conv=c\d+ choice "How are you shopping today\?"')));
      expect(first, matches(RegExp(r'stage=c\d+\* vehicle_card search-\d+ 2 cars\]')));
      expect(ContextRecorder.estimateTokens(first), lessThanOrEqualTo(55));
      // Never a price in the record.
      expect(RegExp(r'\[Screen[^\]]*\$').hasMatch(first), isFalse);
      // The same screen next turn: no line at all.
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('just looking still'),
      );
      expect(s.driver.prompts.last, isNot(contains('[Screen ')));
    });

    testWidgets('what changed travels with the next turn: the person\'s taps on the stage', (
      tester,
    ) async {
      final s = await _start(tester, fullscreen: false);
      final chat = s.container.read(chatServiceProvider.notifier);
      await _turn(tester, s, () => chat.send('just looking around'));
      s.container.read(stageProvider.notifier).setMode(StageMode.web);
      await tester.pumpAndSettle();
      await _turn(tester, s, () => chat.send('just looking still'));
      final p = s.driver.prompts.last;
      expect(p, contains('new=switched to web'));
      // The frame and the active list changed with it (the cards are
      // hidden); the goal did not (the opening question is still live), so
      // it is not sent again.
      expect(p, contains('view=web'));
      expect(p, matches(RegExp(r'stage=c\d+~ vehicle_card')));
      expect(p, isNot(contains('goal=')));
      // The turn's stats carry the context's size.
      expect(s.container.read(turnStatsProvider).first.contextTokens, greaterThan(0));
    });

    testWidgets('a long absence is told to the model, which may orient the person', (tester) async {
      final s = await _start(tester, fullscreen: false);
      final chat = s.container.read(chatServiceProvider.notifier);
      await _turn(tester, s, () => chat.send('just looking around'));
      final before = s.driver.prompts.length;
      final t0 = DateTime(2026, 11, 8, 9);
      // A glance away: nothing.
      chat
        ..appHidden(now: t0)
        ..appShown(now: t0.add(const Duration(seconds: 30)));
      await tester.pumpAndSettle();
      expect(s.driver.prompts, hasLength(before));
      // Forty minutes: a quiet turn, with the absence in its record.
      chat.appHidden(now: t0);
      await _turn(tester, s, () async => chat.appShown(now: t0.add(const Duration(minutes: 40))));
      final p = s.driver.prompts.last;
      expect(p, contains('came back after 40m'));
      expect(p, contains('new=returned 40m'));
      expect(s.container.read(turnStatsProvider).first.detail, 'returned');
      // No bubble for the person, who said nothing.
      expect(
        s.container.read(chatServiceProvider).messages.where((m) => m.text.contains('came back')),
        isEmpty,
      );
    });

    testWidgets('the session warms up at launch, and a first turn waits for it', (tester) async {
      final gate = Completer<void>();
      final s = await _start(tester, warmGate: gate);
      expect(s.driver.warmUps.single, contains('[Screen '));
      final sent = s.container.read(chatServiceProvider.notifier).send('hello there');
      await tester.pump();
      // The person's words are on screen at once; the model gets them when
      // the warm-up is done, not on top of it.
      expect(find.text('hello there'), findsOneWidget);
      expect(s.driver.prompts, isEmpty);
      gate.complete();
      await tester.runAsync(() async {
        await sent;
        await _untilIdle(s.container);
      });
      await tester.pumpAndSettle();
      // The warm-up already told it what is on screen.
      expect(s.driver.prompts.single, isNot(contains('[Screen ')));
      final triggers = s.container.read(turnStatsProvider).map((t) => t.trigger);
      expect(triggers, [TurnTrigger.typed, TurnTrigger.warmUp]);
    });

    testWidgets('a full window reopens the session and sends again, once', (tester) async {
      final s = await _start(tester);
      final opened = s.driver.systemInstructions.length;
      s.driver.overflowsLeft = 1;
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('a long story about my budget'),
      );
      final chat = s.container.read(chatServiceProvider);
      expect(chat.error, isNull);
      expect(s.driver.systemInstructions.length, opened + 1); // one new session
      expect(chat.messages.where((m) => m.text == 'a long story about my budget'), hasLength(1));
      expect(chat.messages.last.text, 'Here is the short version.');
    });

    testWidgets('a window that is still full after reopening says so', (tester) async {
      final s = await _start(tester);
      s.driver.overflowsLeft = 2;
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('a long story again'),
      );
      expect(s.container.read(chatServiceProvider).error, ChatStrings.contextFull);
    });

    testWidgets('a choice prompt renders options and tapping one sends it', (tester) async {
      final s = await _start(tester);
      await _turn(tester, s, () => s.container.read(chatServiceProvider.notifier).send('hi'));
      // The opening mode prompt stays live and the model's choice joins it.
      expect(find.byKey(const Key('card-choice')), findsNWidgets(2));
      expect(_hintOf(tester), ChatStrings.hintPending);
      await _turn(tester, s, () => tester.tap(find.byKey(const Key('choice-buying'))));
      expect(
        s.container.read(chatServiceProvider).messages.map((m) => m.text),
        contains('Buying now'),
      );
    });

    testWidgets('a question can be set aside; it collapses and the model hears of it', (
      tester,
    ) async {
      final s = await _start(tester);
      expect(find.byKey(const Key('card-choice')), findsOneWidget);
      // No turn needed: it leaves the screen at once.
      await tester.tap(find.byKey(const Key('dismiss-choice')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('card-choice')), findsNothing);
      expect(find.textContaining(ChatStrings.setAside), findsOneWidget);
      expect(s.driver.prompts, isEmpty);
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('just looking around'),
      );
      final p = s.driver.prompts.last;
      expect(p, matches(RegExp(r'new=set aside c\d+')));
      // Off the active list too: nothing is live in the conversation.
      expect(p, contains('conv=none'));
    });

    testWidgets('the model opens the filters card or sets a question aside by its id', (
      tester,
    ) async {
      final s = await _start(tester, fullscreen: false);
      await _chooseMode(tester, s, 'browsing');
      final chat = s.container.read(chatServiceProvider.notifier);
      int idOf(String component) => s.container
          .read(chatServiceProvider)
          .timeline
          .whereType<ComponentEntry>()
          .lastWhere((e) => e.shown.request.component.id == component)
          .shown
          .id;
      await _turn(tester, s, () => chat.send('focus c${idOf('search_filters')}'));
      expect(s.container.read(searchProvider).userExpanded, isTrue);
      final question = s.container
          .read(chatServiceProvider)
          .timeline
          .whereType<ComponentEntry>()
          .where((e) => e.shown.request.component.id == 'choice' && !e.shown.answered)
          .lastOrNull;
      if (question != null) {
        await _turn(tester, s, () => chat.send('close c${question.shown.id}'));
        final after = s.container
            .read(chatServiceProvider)
            .timeline
            .whereType<ComponentEntry>()
            .firstWhere((e) => e.shown.id == question.shown.id);
        expect(after.shown.dismissed, isTrue);
      }
    });

    testWidgets('tapping an opening mode chip sets the mode and sends a sentence', (tester) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'practical');
      expect(s.container.read(chatServiceProvider.notifier).profile.mode, ShoppingMode.practical);
      // The person's words come last, after the app's context lines.
      expect(s.driver.prompts.single, endsWith('I want practical options that fit my budget.'));
      expect(find.byKey(const Key('card-search_filters')), findsOneWidget);
    });

    testWidgets('a tap during a turn is refused rather than lost', (tester) async {
      final s = await _start(tester);
      await tester.runAsync(() async {
        // The 'never answer' turn hangs; the chip tap during it must not
        // retire the prompt.
        final started = s.driver.started;
        unawaited(s.container.read(chatServiceProvider.notifier).send('never answer'));
        await started;
        await s.container
            .read(chatServiceProvider.notifier)
            .choose('mode-browsing', 'Just looking');
      });
      await tester.pump();
      expect(find.byKey(const Key('choice-mode-browsing')), findsOneWidget);
      expect(s.container.read(chatServiceProvider).busy, isTrue);
      await tester.runAsync(() => s.container.read(chatServiceProvider.notifier).interrupt());
    });
  });

  group('filters card', () {
    testWidgets('dream car says what it did, offers kinds, and a kind chip filters at once', (
      tester,
    ) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'dreaming');
      // The dream-car starter offers kinds; the one-time hint says the
      // screen is negotiable.
      expect(find.byKey(const Key('choice-${Starters.kindPrefix}coupe')), findsOneWidget);
      expect(find.text(Starters.negotiableNote), findsOneWidget);
      await _turn(tester, s, () => tester.tap(find.byKey(const Key('choice-kind-convertible'))));
      expect(s.container.read(searchProvider).query.bodyStyle, 'convertible');
    });

    testWidgets('chips apply at once and the model is told what is set', (tester) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'browsing');
      expect(_hintOf(tester), ChatStrings.hintDefault);
      await _tapFilter(tester, 'price-40000');
      expect(s.container.read(searchProvider).query.maxPrice, 40000);
      expect(s.container.read(searchProvider).query.minPrice, 25000);
      expect(_hintOf(tester), ChatStrings.hintFiltered);
      // The fake page had two listings; one is under 35k (filtered here, not
      // by the fake site).
      expect(s.container.read(searchProvider).lastCount, 1);
      expect(s.container.read(listingStoreProvider).all, hasLength(2));
      expect(
        tester.widget<Text>(find.byKey(const Key('search-status'))).data,
        ChatStrings.matchedCount(1),
      );
      // Site choice sticks: the search re-applies there.
      await _tapFilter(tester, 'site-autotrader');
      expect(s.container.read(searchProvider).siteId, 'autotrader');
      // Typing a description applies obvious filters before the model answers,
      // and the model is told the current search without it showing in the bubble.
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('a Honda sports car'),
      );
      final q = s.container.read(searchProvider).query;
      expect(q.bodyStyle, 'coupe');
      expect(q.make, 'Honda');
      expect(s.driver.prompts.last, contains('[Already set on the filter card: '));
      expect(s.driver.prompts.last, contains('Honda'));
      expect(find.text('a Honda sports car'), findsOneWidget);
      expect(find.textContaining('[Already set'), findsNothing);
    });

    testWidgets('search notes do not repeat, and the card collapses when docked', (tester) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'browsing');
      await _tapFilter(tester, 'price-40000');
      await _tapFilter(tester, 'price-25000');
      // Two searches in a row leave one note, and it names the latest search.
      final notes = s.container.read(chatServiceProvider).messages.where((m) => m.isSearchNote);
      expect(notes, hasLength(1));
      expect(s.container.read(searchProvider).query.maxPrice, 25000);
      expect(find.text(_searchNoteNow(s.container)), findsOneWidget);
      // Fullscreen keeps the full card; docked collapses it to a summary with
      // a funnel, and the notes go out of view.
      expect(find.byKey(const Key('filters-summary')), findsNothing);
      await tester.tap(find.byKey(const Key('surface-toggle'))); // fullscreen -> collapsed
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('surface-bubble')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filters-summary')), findsOneWidget);
      expect(find.text(_searchNoteNow(s.container)), findsNothing);
      // The person can reopen it, and that choice sticks until a filter changes.
      await tester.tap(find.byKey(const Key('filters-summary')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('filters-summary')), findsNothing);
      expect(s.container.read(searchProvider).userExpanded, isTrue);
      await _tapFilter(tester, 'body-suv');
      expect(s.container.read(searchProvider).userExpanded, isNull);
      expect(find.byKey(const Key('filters-summary')), findsOneWidget);
    });
  });

  group('cards stage', () {
    testWidgets('Monthly cost? asks with the listed price in the person\'s own words', (
      tester,
    ) async {
      final s = await _start(tester, fullscreen: false);
      await tester.tap(find.text('2021 Honda CR-V EX'));
      await tester.pumpAndSettle();
      await _turn(
        tester,
        s,
        () => tester.tap(find.byKey(const Key('ask-cost-2021 Honda CR-V EX|27995'))),
      );
      // The price is the person's to ask about, so the calculation it leads
      // to is allowed; a price only read off the page would not be.
      expect(
        s.driver.prompts.last,
        endsWith('What would the 2021 Honda CR-V EX, listed at \$27,995, cost me a month?'),
      );
      expect(s.container.read(turnStatsProvider).first.trigger, TurnTrigger.tileCost);
      // The app wrote that sentence; it does not become a search for Hondas
      // under \$27,995.
      expect(s.container.read(searchProvider).query.isEmpty, isTrue);
    });

    testWidgets('dead taps on the stage make Motormind ask; a bigger view follows', (tester) async {
      final s = await _start(tester, fullscreen: false);
      final header = find.textContaining('Listings ·');
      expect(header, findsOneWidget);
      // The card's header does nothing when tapped: three taps, no change.
      for (var i = 0; i < TapJournal.threshold; i++) {
        await tester.tap(header);
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      final asked = s.container
          .read(chatServiceProvider)
          .timeline
          .whereType<ComponentEntry>()
          .where((e) => e.shown.request.props['question'] == ChatStrings.deadTapQuestion);
      expect(asked, hasLength(1));
      await s.container
          .read(chatServiceProvider.notifier)
          .choose(
            '${ChatService.lookPrefix}bigger',
            ChatStrings.lookBigger,
            source: asked.single.shown,
          );
      await tester.pumpAndSettle();
      // On the cards, a bigger view is the cards with the panel out of the way.
      expect(s.container.read(surfaceProvider), SurfaceState.collapsed);
      // The model hears which card it was, with the next turn.
      await _turn(tester, s, () => s.container.read(chatServiceProvider.notifier).send('hm'));
      expect(s.driver.prompts.last, contains('tapped the listings card'));
    });

    testWidgets('opening a second listing lets the model choose a side-by-side', (tester) async {
      final s = await _start(tester, fullscreen: false);
      await _chooseMode(tester, s, 'browsing');
      final before = s.driver.prompts.length;
      await tester.tap(find.text('2021 Honda CR-V EX'));
      await tester.pumpAndSettle();
      expect(s.driver.prompts, hasLength(before)); // one listing: nothing asked
      await _turn(tester, s, () => tester.tap(find.text('2023 BMW X3')));
      // The model was told which two, by id and name, never their prices.
      final cue = s.driver.prompts.last;
      expect(cue, contains('opened two listings'));
      expect(cue, isNot(contains('27995')));
      expect(cue, isNot(contains('41000')));
      // No bubble for the person, who said nothing.
      expect(
        s.container.read(chatServiceProvider).messages.where((m) => m.text.contains('[The person')),
        isEmpty,
      );
      // The model chose the compare; it is on the stage, focused.
      final stage = s.container.read(stageProvider);
      expect(stage.focused!.request.component.id, 'vehicle_compare');
      expect(find.byKey(const Key('compare-L1')), findsOneWidget);
      expect(find.byKey(const Key('compare-L2')), findsOneWidget);
      // Beside the listings, not in place of them.
      expect(stage.cards.map((c) => c.request.component.id), contains('vehicle_card'));
      // Its stats say what started it.
      expect(s.container.read(turnStatsProvider).first.trigger, TurnTrigger.signal);

      // Asked to go back, the model focuses the listings card already there
      // instead of adding a copy.
      final count = stage.cards.length;
      final chat = s.container.read(chatServiceProvider.notifier);
      await _turn(tester, s, () => chat.send('back to the list'));
      var now = s.container.read(stageProvider);
      expect(now.cards, hasLength(count));
      expect(now.focused!.request.component.id, 'vehicle_card');
      expect(now.mode, StageMode.cards);

      // By the app's id, as the active list names it; an id that is not
      // there gets the stage's list back, and nothing changes.
      await _turn(tester, s, () => chat.send('close c999'));
      expect(s.container.read(stageProvider).cards, hasLength(count));
      final listingsId = now.cards.firstWhere((c) => c.request.component.id == 'vehicle_card').id;
      expect(s.driver.prompts.last, contains('stage='));
      await _turn(tester, s, () => chat.send('close c$listingsId'));
      now = s.container.read(stageProvider);
      expect(now.cards.map((c) => c.request.component.id), isNot(contains('vehicle_card')));

      // Closed, the compare leaves the stage; a second close finds nothing.
      await _turn(tester, s, () => chat.send('close the comparison'));
      now = s.container.read(stageProvider);
      expect(now.cards.map((c) => c.request.component.id), isNot(contains('vehicle_compare')));
      expect(find.byKey(const Key('compare-L1')), findsNothing);
    });

    testWidgets('three quick taps on one tile make Motormind ask, and a bigger photo follows', (
      tester,
    ) async {
      final s = await _start(tester, fullscreen: false);
      await _chooseMode(tester, s, 'browsing');
      final tile = find.byKey(const Key('listing-2021 Honda CR-V EX|27995'));
      expect(tile, findsOneWidget);
      // On the title, not the tile's center: an open tile has chips there.
      final title = find.descendant(of: tile, matching: find.text('2021 Honda CR-V EX'));
      for (var i = 0; i < RepeatedTaps.threshold; i++) {
        await tester.tap(title);
        await tester.pumpAndSettle();
      }
      // The app asks at once; no model turn is involved. The docked list is
      // lazy, so the question is checked on the timeline and the chip is
      // scrolled into view.
      expect(
        s.container
            .read(chatServiceProvider)
            .timeline
            .whereType<ComponentEntry>()
            .any((e) => e.shown.request.props['question'] == ChatStrings.tappingQuestion),
        isTrue,
      );
      expect(s.driver.prompts.where((p) => p.contains('tapped the same listing')), isEmpty);
      final photoChip = find.byKey(const Key('choice-${ChatService.attentionPrefix}photo'));
      await tester.scrollUntilVisible(
        photoChip,
        80,
        scrollable: find
            .descendant(of: find.byKey(const Key('chat-list')), matching: find.byType(Scrollable))
            .first,
      );
      await tester.tap(photoChip);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('big-photo-2021 Honda CR-V EX|27995')), findsOneWidget);
      // The next turn tells the model what happened.
      await _turn(tester, s, () => s.container.read(chatServiceProvider.notifier).send('nice'));
      expect(s.driver.prompts.last, contains('asked for: photo'));
    });

    testWidgets('a search brings the Cards stage forward with attributed, tappable tiles', (
      tester,
    ) async {
      final s = await _start(tester);
      await _chooseMode(tester, s, 'browsing');
      expect(find.byKey(const Key('display-indicator')), findsOneWidget);
      expect(s.container.read(displayProvider).by, DecidedBy.rules);
      await _tapFilter(tester, 'body-suv');
      expect(s.container.read(stageProvider).mode, StageMode.cards);
      expect(s.container.read(displayProvider).split, StageSplit.twoThirds);
      await tester.tap(find.byKey(const Key('surface-toggle'))); // fullscreen -> collapsed
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('surface-bubble'))); // -> docked
      await tester.pumpAndSettle();
      expect(_paneParked(tester), isTrue);
      // Every tile names its source and its age.
      expect(find.textContaining('${CuratedSites.nameFor('echopark')} · '), findsNWidgets(2));
      // Tapping a tile opens its detail in place and marks it viewed.
      await tester.tap(find.byKey(Key('listing-$_crvKey')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('open-site-$_crvKey')), findsOneWidget);
      expect(s.container.read(listingSignalsProvider).viewed, hasLength(1));
      await tester.tap(find.byKey(Key('like-$_crvKey')));
      await tester.pumpAndSettle();
      expect(s.container.read(listingSignalsProvider).liked, hasLength(1));
      // "Not this one" hides the tile.
      await tester.tap(find.byKey(Key('dismiss-$_crvKey')));
      await tester.pumpAndSettle();
      expect(find.byKey(Key('listing-$_crvKey')), findsNothing);
      // The person's flip to Web wins over the decision.
      await tester.tap(
        find.descendant(of: find.byKey(const Key('stage-mode')), matching: find.text('Web')),
      );
      await tester.pumpAndSettle();
      expect(s.container.read(stageProvider).mode, StageMode.web);
      expect(find.byKey(const Key('browser-pane')), findsOneWidget);
    });
  });

  group('guards and failures', () {
    testWidgets('a number the model invented is replaced and noted', (tester) async {
      final s = await _start(tester);
      await _turn(
        tester,
        s,
        () => s.container.read(chatServiceProvider.notifier).send('invent a number'),
      );
      expect(find.byKey(const Key('guard-note')), findsOneWidget);
      expect(find.textContaining('\$999'), findsNothing);
    });

    testWidgets('sales language raises a banner the person can dismiss', (tester) async {
      final s = await _start(tester);
      await _turn(tester, s, () => s.container.read(chatServiceProvider.notifier).send('sell me'));
      expect(find.byKey(const Key('policy-banner')), findsOneWidget);
      await tester.tap(find.byKey(const Key('policy-dismiss')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('policy-banner')), findsNothing);
    });

    testWidgets('the idle watchdog stops a silent turn and says so', (tester) async {
      const idleLimit = Duration(milliseconds: 30);
      final s = await _start(tester, idleLimit: idleLimit);
      await tester.runAsync(() async {
        await s.container.read(chatServiceProvider.notifier).send('never answer');
      });
      await tester.pumpAndSettle();
      expect(
        tester.widget<Text>(find.byKey(const Key('chat-error'))).data,
        ChatStrings.stoppedAfter(idleLimit.inSeconds),
      );
      expect(s.container.read(chatServiceProvider).busy, isFalse);
    });

    testWidgets('without a model, starting explains what to do', (tester) async {
      // No driver factory: the service falls back to the model loader, which
      // has nothing loaded.
      await tester.pumpWidget(await motormindApp(acknowledgedVersion: Disclosures.gateVersion));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('surface-bubble')));
      await tester.pumpAndSettle();
      final container = containerOf(tester);
      await tester.runAsync(() => container.read(chatServiceProvider.notifier).start());
      await tester.pumpAndSettle();
      expect(find.text(ChatStrings.noModel), findsOneWidget);
    });
  });

  group('plain text', () {
    test('markdown markers and escaped dollars are stripped', () {
      expect(plainText(r'**Bold** and \$430'), r'Bold and $430');
      expect(plainText('- one\n- two'), '• one\n• two');
    });
  });
}
