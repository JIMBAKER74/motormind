import 'dart:async';

import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/advisor_model_service.dart';
import '../../services/log.dart';
import '../advisor/advisor_surface.dart';
import '../advisor/display_agent.dart';
import '../advisor/stage.dart';
import '../advisor/tap_journal.dart';
import '../browser/browser_service.dart';
import '../listings/listing_signals.dart';
import '../models/model_catalog.dart';
import '../search/search_service.dart';
import 'cards/formatting.dart';
import 'chat_state.dart';
import 'chat_strings.dart';
import 'edge_ai_chat_driver.dart';
import 'external_tools.dart';
import 'prompt_assets.dart';
import 'starters.dart';
import 'turn_stats.dart';

export 'chat_state.dart';

/// Factory seam so tests can inject a scripted [ChatDriver].
typedef ChatDriverFactory = Future<ChatDriver> Function(String systemInstruction);

final chatDriverFactoryProvider = Provider<ChatDriverFactory?>((ref) => null);

/// How long a turn may go with no event (no token, no tool) before the app
/// stops it. Null disables it (tests). Generous for the emulator's CPU; a
/// phone should trip this far less often.
final turnIdleLimitProvider = Provider<Duration?>((ref) => const Duration(seconds: 75));

final chatServiceProvider = NotifierProvider<ChatService, ChatState>(ChatService.new);

final class ChatService extends Notifier<ChatState> {
  TurnPipeline? _pipeline;
  ChatDriver? _driver;

  /// The turn in flight, so an interrupt can wait for it to wind down.
  Future<void>? _turn;

  ComponentIds get _componentIds => ref.read(componentIdsProvider);

  @override
  ChatState build() {
    ref.onDispose(() => _driver?.close());
    // Every applied search becomes one note in the conversation, so the
    // transcript shows what the person chose. A consecutive note is replaced
    // and an identical one skipped, so the transcript never repeats itself.
    ref.listen(searchProvider, (previous, next) {
      if (!state.ready || next.applying || next.lastCount == null) return;
      if (previous?.lastCount == next.lastCount && previous?.query == next.query) return;
      _noteSearch(next);
    });
    return const ChatState();
  }

  void _noteSearch(SearchState s) {
    final line = ChatStrings.searchNote(s.query.describe(), s.siteName, s.lastCount ?? 0);
    final t = [...state.timeline];
    final last = t.lastOrNull;
    if (last is MessageEntry &&
        last.message.role == MessageRole.system &&
        last.message.isSearchNote) {
      if (last.message.text == line) return;
      t.removeLast();
    }
    state = state.copyWith(timeline: [...t, MessageEntry(ChatMessage.searchNote(line))]);
  }

  /// Opens a chat on the active model. Call again to start a new conversation.
  Future<void> start() async {
    state = state.copyWith(busy: true, clearError: true);
    try {
      final profile = _pipeline?.profile ?? const BuyerProfile();
      if (!await _openSession(profile)) {
        state = state.copyWith(busy: false, error: ChatStrings.noModel);
        return;
      }
      // A fresh conversation: every flag from the previous one is dropped.
      state = ChatState(
        ready: true,
        timeline: [ComponentEntry(Starters.openingPrompt(profile, _componentIds))],
      );
    } on Exception catch (e) {
      logDev('start failed: $e');
      state = state.copyWith(busy: false, error: ChatStrings.startFailed);
    }
  }

  /// Opens a model session and a pipeline for [profile], closing the old
  /// one first. False when no model is loaded. The timeline is not touched,
  /// so [start] and the full-window recovery in [_runTurn] share it.
  Future<bool> _openSession(BuyerProfile profile) async {
    final builder = await ref.read(promptAssetsProvider.future);
    final instruction = builder.build(profile: profile, viewport: _viewport());
    final factory = ref.read(chatDriverFactoryProvider);
    ChatDriver driver;
    if (factory != null) {
      driver = await factory(instruction);
    } else {
      final models = ref.read(advisorModelServiceProvider.notifier);
      // A conversation that starts while the model is still loading waits
      // for it rather than failing; the panel shows the load meanwhile.
      final model = await models.whenLoaded();
      final activeId = ref.read(advisorModelServiceProvider).value?.activeId;
      final spec = activeId == null ? null : ModelCatalog.byId(activeId);
      if (model == null || spec == null) return false;
      // Close the previous chat before opening the next so two sessions
      // never sit in device memory at once.
      await _driver?.close();
      _driver = null;
      driver = await EdgeAiChatDriver.open(model, spec, systemInstruction: instruction);
    }
    await _driver?.close();
    _driver = driver;
    // A new session has seen no screen line yet.
    _lastScreenLine = null;
    _pipeline = TurnPipeline(
      driver: driver,
      profile: profile,
      external: ref.read(externalToolsProvider).call,
    );
    return true;
  }

  /// The canvas, for the opening context (design notes DD-R10): size and
  /// posture are stable for a session; the keyboard changes per turn and is
  /// in the per-turn screen line instead. Null where there is no view.
  ViewportDescriptor? _viewport() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return null;
    final v = views.first;
    final size = v.physicalSize / v.devicePixelRatio;
    if (size.isEmpty) return null;
    return ViewportDescriptor(
      widthDp: size.width,
      heightDp: size.height,
      // Material's compact width is below 600 dp; an unfolded Fold is wider.
      posture: size.width >= _wideWidthDp ? 'wide' : 'phone',
    );
  }

  /// Width from which the canvas is described as wide (a tablet or an
  /// unfolded foldable), after Material's window size classes.
  static const _wideWidthDp = 600;

  /// The screen line the model was last given; the next is sent only if it
  /// differs ("say what changed", design notes principle 16).
  String? _lastScreenLine;

  /// Longest question text quoted in the screen line.
  static const _screenQuestionChars = 60;

  /// Most stage components named in the screen line.
  static const _screenStageItems = 4;

  /// What is on screen, in one bracketed line for the model: the shopping
  /// mode, the stage's components by id and state, what is live in the
  /// conversation, the keyboard. Names, ids, counts and states only, never a
  /// price or the person's numbers (design notes 5.3, the context record).
  String _screenLine(ShoppingMode? mode) {
    final stage = ref.read(stageProvider);
    final focused = stage.focused;
    final parts = <String>[];
    for (final c in stage.cards.take(_screenStageItems)) {
      final id = c.request.component.id;
      final r = c.result;
      final focus = identical(c, focused) ? ', focused' : '';
      final what = switch (id) {
        'vehicle_card' => switch (listingsOf(r).length) {
          0 => 'listings (none)',
          final n => 'listings ${r?.id}: L1-L$n, $n cars',
        },
        'vehicle_compare' => 'compare ${(c.request.props['ids'] as List?)?.join(', ') ?? ''}',
        _ => r == null ? id : '$id ${r.id}',
      };
      parts.add('$what$focus');
    }
    final live = [
      for (final e in state.timeline)
        if (e is ComponentEntry && !e.shown.answered && e.shown.request.component.isInteraction)
          // From the search, not the display decision: the display
          // controller watches this service, so reading it here would loop.
          e.shown.request.component.id == 'search_filters'
              ? 'filters card (${ref.read(searchProvider).query.isEmpty ? 'nothing set' : 'set'})'
              : '${e.shown.request.component.id} "${_clip('${e.shown.request.props['question'] ?? e.shown.request.props['title'] ?? ''}')}"',
    ];
    return '[Screen: the person is ${mode?.words ?? 'not yet saying how they shop'}; '
        'stage ${stage.mode.name}${parts.isEmpty ? '' : ': ${parts.join('; ')}'}; '
        'conversation: ${live.isEmpty ? 'nothing waiting' : live.join('; ')}; '
        'keyboard ${ref.read(keyboardOpenProvider) ? 'up' : 'down'}.]';
  }

  /// A value's shape: map keys with their shapes, a list's length and its
  /// first element's shape, else the type name. No values.
  static String _shape(Object? v) => switch (v) {
    final Map m => '{${m.entries.map((e) => '${e.key}: ${_shape(e.value)}').join(', ')}}',
    final List l => 'List(${l.length})${l.isEmpty ? '' : ' of ${_shape(l.first)}'}',
    null => 'null',
    _ => v.runtimeType.toString(),
  };

  static String _clip(String s) =>
      s.length <= _screenQuestionChars ? s : '${s.substring(0, _screenQuestionChars)}…';

  void _replaceEntry(int index, TimelineEntry entry) {
    final t = [...state.timeline];
    t[index] = entry;
    state = state.copyWith(timeline: t);
  }

  /// [filtersCardComing] is set by [choose] when the filters card is about to
  /// join the conversation, so the first turn already knows it is on screen.
  /// [trigger] and [detail] say what started the turn, for its stats (an
  /// option id or a tile, never the person's words).
  Future<void> send(
    String text, {
    bool filtersCardComing = false,
    TurnTrigger trigger = TurnTrigger.typed,
    String detail = '',
  }) async {
    return _send(text, filtersCardComing: filtersCardComing, trigger: trigger, detail: detail);
  }

  Future<void> _send(
    String text, {
    bool filtersCardComing = false,
    bool reopened = false,
    TurnTrigger trigger = TurnTrigger.typed,
    String detail = '',
  }) async {
    if (text.trim().isEmpty) return;
    // Motormind is always on: a message typed before the conversation has
    // started (the model still loading) starts it and then goes through,
    // instead of meeting a disabled box (the owner's note, 2026-10-12).
    if (_pipeline == null) {
      if (!state.busy) await start();
      if (_pipeline == null) return; // start() said why in state.error
    }
    final pipeline = _pipeline!;
    if (state.busy) return;
    return _turn = _runTurn(
      pipeline,
      text,
      filtersCardComing: filtersCardComing,
      reopened: reopened,
      trigger: trigger,
      detail: detail,
    );
  }

  Future<void> _runTurn(
    TurnPipeline pipeline,
    String text, {
    required bool filtersCardComing,
    bool reopened = false,
    TurnTrigger trigger = TurnTrigger.typed,
    String detail = '',
  }) async {
    var reopen = false;
    final clock = Stopwatch()..start();
    int? firstTextMs;
    var pieces = 0;
    var failed = false;
    final tools = <(String, int)>[];
    // A turn the app started from something it noticed: no bubble for the
    // person (they said nothing), no filters inferred from the text, and a
    // reply bubble only if the model says something.
    final quiet = trigger == TurnTrigger.signal;
    final userMsg = ChatMessage(role: MessageRole.user, text: text.trim());
    var reply = const ChatMessage(role: MessageRole.motormind, text: '', streaming: true);
    // The obvious filters in a sentence ("a Honda sports car under 40k") apply
    // before the model has read it, so the page is already changing.
    // Only from what the person typed: a sentence the app writes for them
    // ("…, listed at \$14,496, cost me a month?") once set the search to
    // Hyundai under \$14,496 and reloaded the page mid-turn.
    if (trigger == TurnTrigger.typed) ref.read(searchProvider.notifier).updateFromText(text);
    // The model is told the current search (it cannot see the card); the
    // bubble shows only what the person typed.
    final search = ref.read(searchProvider);
    final hasFiltersCard =
        filtersCardComing ||
        state.timeline.any(
          (e) => e is ComponentEntry && e.shown.request.component.id == 'search_filters',
        );
    final siteName = CuratedSites.nameFor(search.siteId);
    final signals = ref.read(listingSignalsProvider.notifier).summary(_listingsOnStage());
    final noticed = _signals.isEmpty ? '' : ' The person ${_signals.join('; ')}.';
    _signals.clear();
    final signalContext = signals == null && noticed.isEmpty
        ? ''
        : '\n[Listings: ${signals ?? 'none viewed'}.$noticed]';
    final searchContext = !hasFiltersCard
        ? ''
        : search.query.isEmpty
        ? '\n\n[A filter card (vehicle type, price, miles, site) is on screen; nothing set yet, '
              'site $siteName. Do not ask what kind or what price; they can tap or tell you.]'
        : '\n\n[Already set on the filter card: ${search.query.describe()} on $siteName; '
              '${search.lastCount ?? 0} listings read. Do not ask about these again.]';
    final screen = _screenLine(pipeline.profile.mode);
    final screenContext = screen == _lastScreenLine ? '' : '\n$screen';
    _lastScreenLine = screen;
    // The app's context lines first and the person's words last: a small
    // model continues what it reads last, and with the screen line last it
    // replied with the bare mode name ("browsing [shopping_mode: browsing]",
    // headless emulator, 2026-11-02).
    final context = (searchContext + signalContext + screenContext).trim();
    final prompt = context.isEmpty ? text.trim() : '$context\n\n${text.trim()}';
    final promptChars = prompt.length;
    // What is on the stage can be named by the model (compare two listings).
    for (final c in ref.read(stageProvider).cards) {
      if (c.result case final r?) pipeline.remember(r);
    }
    state = state.copyWith(
      timeline: [...state.timeline, if (!quiet) MessageEntry(userMsg), MessageEntry(reply)],
      busy: true,
      clearGuardNote: true,
      clearError: true,
      policyFlags: const [],
      turnStartedAt: DateTime.now(),
    );
    var replyIndex = state.timeline.length - 1;
    void updateReply(ChatMessage m) {
      reply = m;
      _replaceEntry(replyIndex, MessageEntry(m));
    }

    try {
      final idleLimit = ref.read(turnIdleLimitProvider);
      Timer? watchdog;
      var stoppedByWatchdog = false;
      void arm() {
        watchdog?.cancel();
        if (idleLimit == null) return;
        watchdog = Timer(idleLimit, () async {
          stoppedByWatchdog = true;
          await _driver?.cancel();
        });
      }

      arm();
      logDev('turn start');
      await for (final e in pipeline.run(prompt)) {
        arm();
        switch (e) {
          case TextDelta(:final text):
            firstTextMs ??= clock.elapsedMilliseconds;
            pieces++;
            updateReply(reply.copyWith(text: reply.text + text));
          case ThinkingDelta():
            break;
          case ToolStarted(:final name, :final args):
            logDev('tool $name');
            // The shape of a present call (keys and value types, no values),
            // so a call the registry refuses can be read off the log.
            if (name == AdvisorTools.present) logDev('present shape: ${_shape(args)}');
            tools.add((name, clock.elapsedMilliseconds));
            state = state.copyWith(activeTool: name);
          case ToolFinished():
            state = state.copyWith(clearActiveTool: true);
          case ProfileUpdated():
            break;
          case Presented(:final result, automatic: true)
              when result?.tool == AdvisorTools.findVehicles:
            // The live search already put this result on the stage.
            break;
          case Presented(:final request, :final result):
            logDev('presented ${request.component.id}${result == null ? '' : ' (${result.id})'}');
            final surface = ref.read(surfaceProvider);
            final toStage =
                !request.component.isInteraction &&
                surface != SurfaceState.fullscreen &&
                request.surface != SurfaceState.fullscreen;
            final shown = ShownComponent(
              id: _componentIds.next(),
              request: request,
              result: result,
            );
            if (toStage) {
              ref.read(stageProvider.notifier).show(shown);
            } else {
              // Replace an earlier card for the same result (auto-present then
              // the model's own present), else insert above the reply.
              final t = [...state.timeline];
              final existing = result == null
                  ? -1
                  : t.indexWhere((e) => e is ComponentEntry && e.shown.result?.id == result.id);
              if (existing >= 0) {
                t[existing] = ComponentEntry(shown);
              } else {
                t.insert(replyIndex, ComponentEntry(shown));
                replyIndex += 1;
              }
              state = state.copyWith(timeline: t);
            }
            if (request.surface == SurfaceState.fullscreen) {
              ref.read(surfaceProvider.notifier).request(SurfaceState.fullscreen);
            }
          case InputRejected(:final arguments):
            state = state.copyWith(guardNote: ChatStrings.refusedInputs(arguments));
          case PresentRejected(:final errors):
            // The registry's own words about the model's call: component
            // ids and field names, never values the person gave.
            logDev('present rejected: ${errors.join('; ')}');
            state = state.copyWith(clearActiveTool: true);
          case GuardTripped(:final report, :final replaced):
            state = state.copyWith(
              guardNote: replaced
                  ? ChatStrings.numbersReplaced
                  : ChatStrings.checkingNumbers(report.unmatched.map((m) => m.raw)),
            );
            if (replaced) updateReply(reply.copyWith(text: ''));
          case PolicyFlagged(:final flags):
            state = state.copyWith(policyFlags: flags);
          case NarrationReplaced(:final text):
            // The guard or the prose-list conversion rewrote the reply; what
            // streamed so far is replaced, not appended to, and the note no
            // longer quotes the numbers that were taken out.
            updateReply(reply.copyWith(text: text));
            if (state.guardNote != null) {
              state = state.copyWith(guardNote: ChatStrings.numbersReplaced);
            }
          case TurnFailed(:final message):
            logDev('turn failed inside the pipeline: $message');
            state = state.copyWith(error: ChatStrings.somethingWrong);
          case TurnDone(:final narration, :final results):
            // Gemma sometimes ends a turn right after a tool call with no
            // words. The screen must still answer, so the app writes the
            // sentence from what it knows (counts, not the model's numbers).
            final mode = Starters.openingChoices[detail]?.$1;
            final text = narration.trim().isNotEmpty
                ? narration
                : quiet
                ? ''
                : (mode != null ? ChatStrings.afterMode(mode) : _silentTurnText(results));
            updateReply(reply.copyWith(text: text, streaming: false));
        }
      }
      watchdog?.cancel();
      if (stoppedByWatchdog) {
        state = state.copyWith(error: ChatStrings.stoppedAfter(idleLimit!.inSeconds));
      }
    } on Exception catch (e) {
      logDev('turn failed: $e');
      failed = true;
      if (quiet) {
        // Nobody asked; a failed look-around is logged, not shown.
      } else if (!reopened && _contextOverflow.hasMatch(e.toString())) {
        // The conversation outgrew the window. The person should not have
        // to know what a window is: open a fresh session that keeps the
        // profile (what they said they want, the mode, their numbers) and
        // the transcript on screen, and send the message again, once. The
        // model loses the earlier turns' wording, not the facts.
        reopen = true;
      } else {
        final msg = _friendly(e);
        updateReply(reply.copyWith(text: reply.text.isEmpty ? msg : reply.text, streaming: false));
        state = state.copyWith(error: msg);
      }
    } finally {
      logDev('turn done');
      state = state.copyWith(busy: false, clearActiveTool: true, clearTurnStartedAt: true);
      ref
          .read(turnStatsProvider.notifier)
          .add(
            TurnStats(
              trigger: reopened ? TurnTrigger.retry : trigger,
              detail: detail,
              startedAt: DateTime.now().subtract(clock.elapsed),
              firstTextMs: firstTextMs,
              totalMs: clock.elapsedMilliseconds,
              promptChars: promptChars,
              outputPieces: pieces,
              tools: tools,
              displayAgentOn: ref.read(displayAgentModeProvider) == DisplayAgentMode.model,
              failed: failed,
            ),
          );
    }
    if (quiet && reply.text.trim().isEmpty) {
      final t = [...state.timeline];
      if (replyIndex < t.length) t.removeAt(replyIndex);
      state = state.copyWith(timeline: t, clearError: true);
    }
    if (!reopen) return;
    // The failed exchange leaves the transcript; the retry writes its own.
    final t = [...state.timeline]..removeAt(replyIndex);
    t.removeWhere((e) => e is MessageEntry && identical(e.message, userMsg));
    t.add(const MessageEntry(ChatMessage(role: MessageRole.system, text: ChatStrings.freshPage)));
    state = state.copyWith(timeline: t, clearError: true);
    logDev('window full: reopening the session and sending again');
    if (!await _openSession(profile)) {
      state = state.copyWith(error: ChatStrings.contextFull);
      return;
    }
    await _send(
      text,
      filtersCardComing: filtersCardComing,
      reopened: true,
      trigger: trigger,
      detail: detail,
    );
  }

  /// The listings currently on the stage.
  List<VehicleListing> _listingsOnStage() => [
    for (final c in ref.read(stageProvider).cards)
      if (c.request.component.id == 'vehicle_card') ...listingsOf(c.result),
  ];

  String _silentTurnText(List<ToolResult> results) {
    final searched = results.any(
      (r) => r.tool == AdvisorTools.findVehicles || r.tool == AdvisorTools.updateSearch,
    );
    if (searched) {
      final s = ref.read(searchProvider);
      final n = s.lastCount ?? 0;
      if (n == 0) return ChatStrings.noMatches(s.siteName, s.query.describe());
      return ChatStrings.matches(n, s.siteName, s.query.describe());
    }
    if (results.isNotEmpty) return ChatStrings.hereIsWhatIFound;
    return ChatStrings.nothingToAdd;
  }

  /// Cancels the generation in flight and waits for the turn to wind down;
  /// whatever was produced so far stays (cards, partial text). The person
  /// can type a new prompt at once.
  Future<void> interrupt() async {
    await _driver?.cancel();
    await _turn;
  }

  /// Dismisses the sales-language banner.
  void clearPolicyFlags() => state = state.copyWith(policyFlags: const []);

  /// The listing Motormind asked about after repeated taps; the answer to
  /// [ChatStrings.tappingQuestion] applies to it.
  VehicleListing? _tappedListing;

  /// Signals the app noticed since the last turn, told to the model with
  /// the next message so it can respond to what the person did, not only
  /// to what they typed (the design notes' per-turn context record).
  final List<String> _signals = [];

  /// Option ids of the choice Motormind offers after repeated taps.
  static const attentionPrefix = 'attention-';

  /// Listings cards that have already prompted a look-around, so the model
  /// is asked once per card, not on every tap after the second.
  final Set<int> _noticedCards = {};

  /// The person opened a second listing in one listings card. The model is
  /// told which two, by id and name (never their prices), and decides what
  /// to show: a side-by-side compare, a question, or nothing. The app does
  /// not choose the component; that is the point (design notes, Q71 and
  /// DD-Q22). Once per card, and only when the conversation is idle.
  Future<void> noticeOpenedTwo(ShownComponent card, List<VehicleListing> opened) async {
    final result = card.result;
    if (result == null || opened.length < 2 || !state.ready || state.busy) return;
    if (!_noticedCards.add(card.id)) return;
    final names = opened.map((l) => '${l.id} ${l.title}').join('; ');
    final ids = opened.map((l) => '"${l.id}"').join(', ');
    // The exact call is spelled out: given only a description, Gemma 4 E2B
    // took the cue but re-presented the listings card instead of the
    // compare (headless emulator, 2026-11-02). It still decides whether to
    // make the call at all.
    await _send(
      '[The person opened two listings from ${result.id}: $names. To show them side by side, '
      'call present with component vehicle_compare, result_id ${result.id} and ids [$ids], '
      'and say one short line; if that would not help, say nothing.]',
      trigger: TurnTrigger.signal,
      detail: 'opened-two',
    );
  }

  /// Motormind noticed the person tapping a listing again and again and asks what
  /// would help, with the things it can do as answers. Nothing is sent to
  /// the model: the question is the app's, at once, and the answer reaches
  /// the model as a signal with the next turn.
  void noticeTapping(VehicleListing l) {
    if (!state.ready) return;
    final pending = state.timeline.any(
      (e) =>
          e is ComponentEntry &&
          !e.shown.answered &&
          e.shown.request.props['question'] == ChatStrings.tappingQuestion,
    );
    if (pending) return;
    _tappedListing = l;
    final shown = validatedComponent({
      'component': 'choice',
      'props': {
        'question': ChatStrings.tappingQuestion,
        'options': [
          {'id': '${attentionPrefix}photo', 'label': ChatStrings.biggerPhoto},
          {'id': '${attentionPrefix}site', 'label': ChatStrings.openOnSite},
          {'id': '${attentionPrefix}no', 'label': ChatStrings.nothingThanks},
        ],
      },
    }, id: _componentIds.next());
    if (shown == null) return;
    _signals.add('tapped the same listing ${RepeatedTaps.threshold} times (${l.title})');
    state = state.copyWith(timeline: [...state.timeline, ComponentEntry(shown)]);
  }

  /// Option ids of the question asked after dead taps anywhere.
  static const lookPrefix = 'look-';

  /// Where the last run of dead taps was ("the cards", "the Motormind
  /// panel"); the answer to the question applies there.
  String? _deadTapRegion;

  /// Taps repeated in one place while nothing on screen changed: Motormind
  /// asks what the person is looking for, with the things it can do at
  /// once as answers, and the model hears about it with the next turn. A
  /// question already waiting (the tile's own) wins.
  void noticeDeadTaps(String region) {
    if (!state.ready) return;
    final pending = state.timeline.any(
      (e) =>
          e is ComponentEntry &&
          !e.shown.answered &&
          (e.shown.request.props['question'] == ChatStrings.tappingQuestion ||
              e.shown.request.props['question'] == ChatStrings.deadTapQuestion),
    );
    if (pending) return;
    _deadTapRegion = region;
    _signals.add('tapped $region ${TapJournal.threshold} times and nothing changed');
    final shown = validatedComponent({
      'component': 'choice',
      'props': {
        'question': ChatStrings.deadTapQuestion,
        'options': [
          {'id': '${lookPrefix}bigger', 'label': ChatStrings.lookBigger},
          {'id': '${lookPrefix}detail', 'label': ChatStrings.lookDetail},
          {'id': '${lookPrefix}no', 'label': ChatStrings.nothingThanks},
        ],
      },
    }, id: _componentIds.next());
    if (shown == null) return;
    state = state.copyWith(timeline: [...state.timeline, ComponentEntry(shown)]);
    // The question is in the conversation; the panel comes up to show it.
    if (ref.read(surfaceProvider) == SurfaceState.collapsed) {
      ref.read(surfaceProvider.notifier).request(SurfaceState.docked);
    }
  }

  /// Answers to [noticeDeadTaps]: a bigger view now, or the model asked to
  /// show more where the person was tapping. True when [id] was one.
  bool _answerLook(String id, ShownComponent? source) {
    if (!id.startsWith(lookPrefix)) return false;
    _markAnswered(source);
    final want = id.substring(lookPrefix.length);
    final region = _deadTapRegion ?? 'the screen';
    _signals.add('asked for: $want');
    switch (want) {
      case 'bigger':
        // The cards get the whole screen, or the panel does.
        ref
            .read(surfaceProvider.notifier)
            .request(region == 'the cards' ? SurfaceState.collapsed : SurfaceState.fullscreen);
      case 'detail':
        unawaited(
          _send(
            '[The person tapped $region repeatedly and wants more detail there. Show it with a '
            'component if one fits, or ask one short question.]',
            trigger: TurnTrigger.signal,
            detail: 'dead-taps',
          ),
        );
      default:
        break;
    }
    return true;
  }

  /// Answers to [noticeTapping]'s question: done by the app at once, and
  /// remembered for the model. Returns true when [id] was one of them.
  bool _answerAttention(String id, ShownComponent? source) {
    if (!id.startsWith(attentionPrefix)) return false;
    _markAnswered(source);
    final l = _tappedListing;
    final want = id.substring(attentionPrefix.length);
    _signals.add('asked for: $want');
    if (l == null) return true;
    final key = ListingSignalsNotifier.keyFor(l);
    switch (want) {
      case 'photo':
        ref.read(bigPhotoProvider.notifier).show(key);
      case 'site':
        final url = l.detailUrl ?? l.sourceUrl;
        if (BrowserService.isWebUrl(url)) {
          unawaited(ref.read(browserProvider.notifier).open(url));
          ref.read(stageProvider.notifier).showWeb();
        }
      default:
        break;
    }
    return true;
  }

  void _markAnswered(ShownComponent? source) {
    if (source == null) return;
    state = state.copyWith(
      timeline: [
        for (final e in state.timeline)
          if (e is ComponentEntry && e.shown.id == source.id)
            ComponentEntry(source.copyWith(answered: true))
          else
            e,
      ],
    );
  }

  /// Answers a choice prompt or a form. [supplement] is text the person typed
  /// alongside the selection: it is sent with the selection. Opening-mode
  /// choices set the mode locally and add the filters card and a starter to
  /// the conversation before the model answers. [source] is the card
  /// answered; it collapses to its question but stays in the transcript.
  Future<void> choose(String id, String label, {String? supplement, ShownComponent? source}) async {
    // The app's own questions are answered by the app, turn or no turn.
    if (_answerAttention(id, source)) return;
    if (_answerLook(id, source)) return;
    // While a turn runs, a tap would mark the card answered and then be
    // dropped by send(); refusing it up front keeps the chips live.
    if (_pipeline == null || state.busy) return;
    if (source != null) {
      final t = [
        for (final e in state.timeline)
          if (e is ComponentEntry && e.shown.id == source.id)
            ComponentEntry(source.copyWith(answered: true))
          else
            e,
      ];
      state = state.copyWith(timeline: t);
    }
    final extra = (supplement ?? '').trim();
    String withExtra(String text) => extra.isEmpty ? text : '$text $extra';
    final opening = Starters.openingChoices[id];
    if (opening != null) {
      final (mode, sentence) = opening;
      _pipeline?.setShoppingMode(mode);
      // The live filters join the conversation the moment a mode is chosen, so
      // the screen responds before the model has said a word: the person
      // should never wait on generation for something the app already knows.
      // The card is app-owned: it tracks the search state.
      // send() is synchronous up to its first await, so the card lands after
      // the sentence and before the reply bubble fills in.
      final turn = send(
        withExtra(sentence),
        filtersCardComing: true,
        trigger: TurnTrigger.choice,
        detail: id,
      );
      if (!state.timeline.any(
        (e) => e is ComponentEntry && e.shown.request.component.id == 'search_filters',
      )) {
        state = state.copyWith(
          timeline: [
            ...state.timeline,
            ComponentEntry(Starters.filtersCard(_componentIds)),
            // Mode starters: the app says what it did and asks,
            // so the person can correct it instead of living with a default.
            if (Starters.forMode(mode, _componentIds) case final starter?) ComponentEntry(starter),
            const MessageEntry(
              ChatMessage(role: MessageRole.system, text: Starters.negotiableNote),
            ),
          ],
        );
      }
      return turn;
    }
    if (id.startsWith(Starters.kindPrefix)) {
      final style = SearchQuery.normalizeBodyStyle(id.substring(Starters.kindPrefix.length));
      if (style != null) ref.read(searchProvider.notifier).update({'body_style': style});
      return send(withExtra('I am looking at a $label.'), trigger: TurnTrigger.choice, detail: id);
    }
    return send(withExtra(label), trigger: TurnTrigger.choice, detail: id);
  }

  BuyerProfile get profile => _pipeline?.profile ?? const BuyerProfile();

  /// The engine's context-window overflow message, the one failure the
  /// person can act on (start a new conversation).
  static final _contextOverflow = RegExp(
    r'exceeds available state|Input token ids are too long|context (window|length)',
  );

  static String _friendly(Object e) {
    if (e is TimeoutException) return ChatStrings.tooLong;
    if (_contextOverflow.hasMatch(e.toString())) return ChatStrings.contextFull;
    return ChatStrings.somethingWrong;
  }
}
