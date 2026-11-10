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
    final line = s.fromMemory
        ? ChatStrings.memoryNote(s.query.describe(), s.lastCount ?? 0)
        : ChatStrings.searchNote(s.query.describe(), s.siteName, s.lastCount ?? 0);
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
      _warmUp(profile);
    } on Exception catch (e) {
      logDev('start failed: $e');
      state = state.copyWith(busy: false, error: ChatStrings.startFailed);
    }
  }

  /// Opens a model session and a pipeline for [profile], closing the old
  /// one first. False when no model is loaded. The timeline is not touched,
  /// so [start] and the full-window recovery in [_runTurn] share it.
  Future<bool> _openSession(BuyerProfile profile) async {
    if (_warming case final warming?) await warming;
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
    // A new session has been told nothing about the screen yet.
    _recorder.reset();
    _pipeline = TurnPipeline(
      driver: driver,
      profile: profile,
      external: ref.read(externalToolsProvider).call,
      arrange: _arrange,
    );
    return true;
  }

  /// The warm-up in flight; a turn waits for it rather than interrupting
  /// it, because stopping a prefill partway would throw away work the turn
  /// is about to need.
  Future<void>? _warming;

  /// Longest the warm-up may run. It ends by itself at the model's first
  /// output, 12 to 14 s on the slowest device measured; past this limit
  /// something is wrong and the person's turn should not wait on it.
  static const warmUpLimit = Duration(seconds: 45);

  /// What the model is told at the warm-up. The model answers a bracketed
  /// line with a component, a short line or nothing, and the driver stops
  /// it at its first output either way.
  static const _warmUpCue = '[The app just opened. Nothing to answer yet.]';

  /// Processes the opening context while the person looks at the cards, so
  /// their first tap answers like a later one (the first turn of a session
  /// took 12 to 14 s to a first word, later turns under 4 s; design notes
  /// Q98). The cost is a few seconds of CPU at every launch.
  void _warmUp(BuyerProfile profile) {
    final driver = _driver;
    if (driver == null) return;
    final clock = Stopwatch()..start();
    final record = _recorder.next(_record(profile.mode), force: true);
    final prompt = '${record.text}\n\n$_warmUpCue';
    _warming = driver.warmUp(prompt).timeout(warmUpLimit, onTimeout: driver.cancel).whenComplete(
      () {
        _warming = null;
        if (!ref.mounted) return;
        ref
            .read(turnStatsProvider.notifier)
            .add(
              TurnStats(
                trigger: TurnTrigger.warmUp,
                detail: 'launch',
                startedAt: DateTime.now().subtract(clock.elapsed),
                totalMs: clock.elapsedMilliseconds,
                promptChars: prompt.length,
                outputPieces: 0,
                tools: const [],
                displayAgentOn: ref.read(displayAgentModeProvider) == DisplayAgentMode.model,
              ),
            );
      },
    );
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

  /// What the model has been told about the screen this session; sends only
  /// what changed (design notes 5.3, principle 16).
  final _recorder = ContextRecorder();

  /// Longest question text quoted in the context record.
  static const _screenQuestionChars = 60;

  /// The context record for this moment: the screen's goal, the frame, the
  /// active list and what changed. Taking it consumes [_changed] and the
  /// stage's record of the person's own changes.
  ContextRecord _record(ShoppingMode? mode) {
    final stage = ref.read(stageProvider);
    final surface = ref.read(surfaceProvider);
    final changed = [..._changed, ...ref.read(stageProvider.notifier).takePersonChanges()];
    _changed.clear();
    return ContextRecord(
      goal: _screenGoal(),
      mode: mode?.words,
      panel: surface.name,
      view: stage.mode.name,
      keyboardUp: ref.read(keyboardOpenProvider),
      active: _activeList(),
      changed: changed,
    );
  }

  /// The components on screen, by the app's ids (DD-R37): live questions
  /// and the filters card in the conversation, then the stage's cards,
  /// newest first. Answered questions are history, not on screen. Names,
  /// ids, counts and states only, never a price or the person's numbers.
  List<ActiveComponent> _activeList() {
    final stage = ref.read(stageProvider);
    final focused = stage.focused;
    return [
      for (final e in state.timeline)
        if (e is ComponentEntry && !e.shown.answered && e.shown.request.component.isInteraction)
          ActiveComponent(
            id: 'c${e.shown.id}',
            component: e.shown.request.component.id,
            region: Region.conversation,
            state: ComponentState.expanded,
            // From the search, not the display decision: the display
            // controller watches this service, so reading it here would loop.
            detail: e.shown.request.component.id == 'search_filters'
                ? (ref.read(searchProvider).query.isEmpty ? 'nothing set' : 'set')
                : '"${_clip('${e.shown.request.props['question'] ?? e.shown.request.props['title'] ?? ''}')}"',
          ),
      for (final c in stage.cards)
        ActiveComponent(
          id: 'c${c.id}',
          component: c.request.component.id,
          region: Region.stage,
          state: stage.mode == StageMode.web
              ? ComponentState.hidden
              : identical(c, focused)
              ? ComponentState.focused
              : ComponentState.summary,
          detail: switch (c.request.component.id) {
            'vehicle_card' => switch (listingsOf(c.result).length) {
              0 => '${c.result?.id} none',
              final n => '${c.result?.id} $n cars',
            },
            'vehicle_compare' => (c.request.props['ids'] as List?)?.join(' ') ?? '',
            _ => c.result?.id ?? '',
          },
        ),
    ];
  }

  /// What the screen is deciding right now, in a few words naming ids
  /// (design notes 5.7, DD-Q20's default): the newest live question, else
  /// the page, else the card shown large. Null when nothing is being
  /// decided. The question's own words are already in the active list.
  String? _screenGoal() {
    final live = state.timeline.reversed
        .whereType<ComponentEntry>()
        .map((e) => e.shown)
        .where(
          (s) =>
              !s.answered &&
              s.request.component.isInteraction &&
              s.request.component.id != 'search_filters',
        )
        .firstOrNull;
    if (live != null) {
      return '${live.request.component.id == 'input_form' ? 'fill in' : 'answer'} c${live.id}';
    }
    final stage = ref.read(stageProvider);
    if (stage.mode == StageMode.web) {
      return 'read the ${CuratedSites.nameFor(ref.read(searchProvider).siteId)} page';
    }
    final f = stage.focused;
    if (f == null) return null;
    return switch (f.request.component.id) {
      'vehicle_card' => listingsOf(f.result).isEmpty ? null : 'pick from c${f.id}',
      'vehicle_compare' => 'compare c${f.id}',
      _ => 'read c${f.id}',
    };
  }

  /// The pipeline's [ArrangeHandler]. A stage card is focused or closed by
  /// the stage. A card live in the conversation is opened or set aside: the
  /// filters card expands or collapses, a question is set aside as if the
  /// person had (the model asked for "help me decide" to focus the filters
  /// card on the headless emulator, 2026-11-10). Anything else gets the
  /// active list back (DD-R38).
  String? _arrange(ArrangeAction action, ArrangeTarget target) {
    if (ref.read(stageProvider.notifier).arrange(action, target)) return null;
    final shown = state.timeline
        .whereType<ComponentEntry>()
        .map((e) => e.shown)
        .where(
          (s) =>
              !s.answered &&
              s.request.component.isInteraction &&
              (target.id != null
                  ? 'c${s.id}' == target.id
                  : s.request.component.id == target.componentId),
        )
        .lastOrNull;
    if (shown == null) {
      final active = _activeList().map((a) => a.describe());
      return '$target is not on screen. On screen: '
          '${active.isEmpty ? 'nothing' : active.join(' | ')}.';
    }
    final filters = shown.request.component.id == 'search_filters';
    switch (action) {
      case ArrangeAction.focus:
        if (filters) ref.read(searchProvider.notifier).setExpanded(true);
        if (ref.read(surfaceProvider) == SurfaceState.collapsed) {
          ref.read(surfaceProvider.notifier).request(SurfaceState.docked);
        }
      case ArrangeAction.close:
        if (filters) {
          ref.read(searchProvider.notifier).setExpanded(false);
        } else {
          _setAside(shown);
        }
    }
    return null;
  }

  /// When the app went to the background; null while in front.
  DateTime? _hiddenAt;

  /// Shorter absences (a glance at a message) are not worth telling the
  /// model about.
  static const returnNoteAfter = Duration(minutes: 1);

  /// After this long away, the model may say one line on where the person
  /// was (design notes DD-R14). Shorter, they remember.
  static const returnCueAfter = Duration(minutes: 10);

  /// The app went to the background (Home, Back on Android, another app).
  void appHidden({DateTime? now}) => _hiddenAt = now ?? DateTime.now();

  /// The app is in front again. The absence goes into the next record as
  /// `returned 40m` (design notes 5.5); after [returnCueAfter], in a
  /// conversation the person has spoken in, the model gets a quiet turn in
  /// which it may orient them or say nothing.
  void appShown({DateTime? now}) {
    final at = _hiddenAt;
    _hiddenAt = null;
    if (at == null) return;
    final away = (now ?? DateTime.now()).difference(at);
    if (away < returnNoteAfter) return;
    final words = away.inHours >= 1 ? '${away.inHours}h' : '${away.inMinutes}m';
    _changed.add('returned $words');
    final spoke = state.messages.any((m) => m.role == MessageRole.user);
    if (away < returnCueAfter || !spoke || !state.ready || state.busy) return;
    unawaited(
      _send(
        '[The person came back after $words. If it would help, say in one short line where '
        'they left off; otherwise say nothing.]',
        trigger: TurnTrigger.signal,
        detail: 'returned',
      ),
    );
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
    final signalContext = signals == null ? '' : '\n[Listings: $signals.]';
    final searchContext = !hasFiltersCard
        ? ''
        : search.query.isEmpty
        ? '\n\n[A filter card (vehicle type, price, miles, site) is on screen; nothing set yet, '
              'site $siteName. Do not ask what kind or what price; they can tap or tell you.]'
        : '\n\n[Already set on the filter card: ${search.query.describe()} on $siteName; '
              '${search.lastCount ?? 0} listings read. Do not ask about these again.]';
    final record = _recorder.next(_record(pipeline.profile.mode));
    final screenContext = record.text.isEmpty ? '' : '\n${record.text}';
    // The app's context lines first and the person's words last: a small
    // model continues what it reads last, and with the screen line last it
    // replied with the bare mode name ("browsing [shopping_mode: browsing]",
    // headless emulator, 2026-11-02).
    final context = (searchContext + signalContext + screenContext).trim();
    final prompt = context.isEmpty ? text.trim() : '$context\n\n${text.trim()}';
    final promptChars = prompt.length;
    final contextTokens = context.isEmpty ? null : ContextRecorder.estimateTokens(context);
    // Field names and sizes only: the record's values stay out of the log.
    if (contextTokens != null) {
      logDev(
        'context ~${contextTokens}tok (record ${record.tokens}tok'
        '${record.fields.isEmpty ? '' : ': ${record.fields.join(', ')}'}'
        '${record.cut > 0 ? ', ${record.cut} cut' : ''})',
      );
    }
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
      if (_warming case final warming?) await warming;
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
            // The shape of the call (keys and value types, no values): Gemma
            // 4 E2B flattens, renames and drops arguments, and what it
            // actually sent is what a refused call has to be fixed against.
            logDev('tool $name ${_shape(args)}');
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
          case Arranged(:final action, :final target):
            logDev('arranged ${action.name} $target');
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
              contextTokens: contextTokens,
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

  /// What happened since the model's last turn (taps, answers to the app's
  /// own questions, a return from the background), oldest first; the
  /// `changed` field of the next context record (design notes 5.3, DD-R42).
  final List<String> _changed = [];

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
    _changed.add('tapped the same listing ${RepeatedTaps.threshold} times (${l.title})');
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
    _changed.add('tapped $region ${TapJournal.threshold} times and nothing changed');
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
    _changed.add('asked for: $want');
    switch (want) {
      case 'bigger':
        // The cards get the whole screen, or the panel does.
        ref
            .read(surfaceProvider.notifier)
            .request(
              region == 'the Motormind panel' ? SurfaceState.fullscreen : SurfaceState.collapsed,
            );
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
    _changed.add('asked for: $want');
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

  /// The person set a question or form aside without answering (design
  /// notes DD-R12). No turn: it leaves the screen at once, even mid-turn,
  /// and the model hears about it with the next turn.
  void dismiss(ShownComponent source) {
    if (source.answered) return;
    _setAside(source);
    _changed.add('set aside c${source.id}');
  }

  void _setAside(ShownComponent source) {
    state = state.copyWith(
      timeline: [
        for (final e in state.timeline)
          if (e is ComponentEntry && e.shown.id == source.id)
            ComponentEntry(source.copyWith(answered: true, dismissed: true))
          else
            e,
      ],
    );
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
