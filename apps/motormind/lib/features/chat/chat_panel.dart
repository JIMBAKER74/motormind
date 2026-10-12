import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/router.dart';
import '../../services/advisor_model_service.dart';
import '../advisor/display_agent.dart';
import '../models/model_catalog.dart';
import '../search/search_service.dart';
import 'chat_service.dart';
import 'chat_strings.dart';
import 'result_card.dart';

/// The conversation: transcript, the components presented into it, turn
/// status, guard and policy notes, and the input. The same panel is the
/// docked half and the fullscreen view; [header] is what the host puts
/// above it.
class ChatPanel extends ConsumerStatefulWidget {
  const ChatPanel({super.key, required this.header});

  final Widget header;

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel> {
  final _input = TextEditingController();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    final svc = ref.read(chatServiceProvider.notifier);
    // A new prompt during a turn restarts with it: interrupt, wait for
    // the turn to wind down, then send.
    if (ref.read(chatServiceProvider).busy) await svc.interrupt();
    await svc.send(text);
    if (!mounted) return;
    _scrollToEnd();
  }

  void _scrollToEnd() {
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final chat = ref.watch(chatServiceProvider);
    final theme = Theme.of(context);
    final showSearchNotes = ref.watch(displayProvider).notes;
    final filtersSet = !ref.watch(searchProvider).query.isEmpty;
    ref.listen(chatServiceProvider, (previous, next) {
      if (previous?.timeline.length != next.timeline.length) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _scrollToEnd();
        });
      }
    });

    return Column(
      children: [
        widget.header,
        if (chat.policyFlags.isNotEmpty)
          MaterialBanner(
            key: const Key('policy-banner'),
            content: Text(
              '${ChatStrings.policyBanner} '
              '(${chat.policyFlags.map((f) => f.category.name).toSet().join(', ')}).',
            ),
            leading: const Icon(Icons.flag_outlined),
            actions: [
              TextButton(
                key: const Key('policy-dismiss'),
                onPressed: ref.read(chatServiceProvider.notifier).clearPolicyFlags,
                child: const Text('OK'),
              ),
            ],
          ),
        if (chat.guardNote case final note?)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(note, key: const Key('guard-note'), style: theme.textTheme.labelSmall),
          ),
        if (chat.error case final error?)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              error,
              key: const Key('chat-error'),
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ),
        Expanded(
          child: !chat.ready
              // No start button: the conversation starts itself when the
              // model is ready, and the input below is live meanwhile.
              ? const SingleChildScrollView(
                  key: Key('chat-start'),
                  padding: EdgeInsets.all(12),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [_ModelStatus()]),
                )
              : ListView(
                  key: const Key('chat-list'),
                  controller: _scroll,
                  padding: const EdgeInsets.all(12),
                  children: [
                    for (final e in chat.timeline)
                      switch (e) {
                        MessageEntry(:final message)
                            when message.isSearchNote && !showSearchNotes =>
                          const SizedBox.shrink(),
                        MessageEntry(:final message) => _Bubble(message: message),
                        ComponentEntry(:final shown) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: ResultCard(
                            shown: shown,
                            onChoice: (id, label) {
                              // A selection sends with whatever was typed.
                              final extra = _input.text;
                              _input.clear();
                              unawaited(
                                ref
                                    .read(chatServiceProvider.notifier)
                                    .choose(id, label, supplement: extra, source: shown),
                              );
                            },
                          ),
                        ),
                      },
                    if (chat.busy && chat.turnStartedAt != null)
                      _TurnStatus(activeTool: chat.activeTool, startedAt: chat.turnStartedAt!),
                  ],
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const Key('chat-input'),
                    controller: _input,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _send(),
                    decoration: InputDecoration(
                      hintText: _hint(pending: chat.hasPendingPrompt, filtersSet: filtersSet),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const Key('chat-send'),
                  onPressed: _send,
                  icon: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The input is the escape from any prompt: the hint says so while a choice
/// or form is live, and invites more once filters exist.
String _hint({required bool pending, required bool filtersSet}) {
  if (pending) return ChatStrings.hintPending;
  if (filtersSet) return ChatStrings.hintFiltered;
  return ChatStrings.hintDefault;
}

/// "Thinking · 12s" (or the running tool) with the interrupt control. Owns
/// its own one-second ticker so the transcript is not rebuilt every second.
class _TurnStatus extends ConsumerStatefulWidget {
  const _TurnStatus({required this.activeTool, required this.startedAt});

  final String? activeTool;
  final DateTime startedAt;

  @override
  ConsumerState<_TurnStatus> createState() => _TurnStatusState();
}

class _TurnStatusState extends ConsumerState<_TurnStatus> {
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = widget.activeTool?.replaceAll('_', ' ') ?? 'Thinking';
    final seconds = DateTime.now().difference(widget.startedAt).inSeconds;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$label · ${seconds}s',
              key: const Key('turn-status'),
              style: theme.textTheme.labelSmall,
            ),
          ),
          IconButton(
            key: const Key('chat-interrupt'),
            tooltip: ChatStrings.showSoFar,
            visualDensity: VisualDensity.compact,
            onPressed: () => unawaited(ref.read(chatServiceProvider.notifier).interrupt()),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message});

  final ChatMessage message;

  /// Bubbles never run edge to edge; a reply reads better narrow.
  static const _maxWidth = 320.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (message.role == MessageRole.system) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(message.text, key: const Key('system-line'), style: theme.textTheme.labelSmall),
      );
    }
    if (message.text.isEmpty && message.streaming) {
      return const Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    if (message.text.isEmpty) return const SizedBox.shrink();
    final isUser = message.role == MessageRole.user;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: _maxWidth),
        decoration: BoxDecoration(
          color: isUser ? theme.colorScheme.primaryContainer : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(plainText(message.text)),
      ),
    );
  }
}

/// Small models emit Markdown and escape dollars; bubbles are plain text for
/// now, so the common markers are stripped rather than shown raw.
String plainText(String text) => text
    .replaceAll(r'\$', r'$')
    .replaceAll('**', '')
    .replaceAllMapped(RegExp(r'^\s*[-*]\s+', multiLine: true), (_) => '• ')
    .trim();

/// What the model is doing while there is no conversation yet, so the
/// start button never sits beside a blank: loading, downloading, or an
/// offer to download the model that fits this phone. Nothing here asks
/// the person to know what a model is; the Models screen is one tap away
/// for anyone who does.
class _ModelStatus extends ConsumerWidget {
  const _ModelStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final models = ref.watch(advisorModelServiceProvider).value;
    if (models == null) return const SizedBox.shrink();
    final service = ref.read(advisorModelServiceProvider.notifier);
    // The model in play: the active one, else whichever is busy, else the
    // one this phone can run.
    final spec =
        ModelCatalog.all.where((m) {
          final s = models.statusOf(m);
          return m.id == models.activeId || s is ModelLoading || s is ModelDownloading;
        }).firstOrNull ??
        models.recommended;
    final status = models.statusOf(spec);
    final Widget body = switch (status) {
      ModelReady() => const SizedBox.shrink(),
      ModelLoading() => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text(ChatStrings.loadingModel(spec.displayName), key: const Key('model-loading')),
        ],
      ),
      ModelDownloading(:final percent) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(ChatStrings.downloadingModel(spec.displayName, percent)),
          const SizedBox(height: 6),
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(value: percent <= 0 ? null : percent / 100),
          ),
        ],
      ),
      ModelInstalled() => const SizedBox.shrink(), // loading is about to start
      ModelNotInstalled() => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(ChatStrings.noModel, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            key: const Key('model-download'),
            onPressed: () => service.download(spec),
            icon: const Icon(Icons.download),
            label: Text(ChatStrings.downloadModel(spec.displayName, spec.sizeLabel)),
          ),
        ],
      ),
      ModelFailed(:final message) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, style: TextStyle(color: theme.colorScheme.error)),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: () => service.download(spec),
            child: const Text(ChatStrings.modelRetry),
          ),
        ],
      ),
    };
    if (status is ModelReady) return body;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          body,
          TextButton(
            onPressed: () => context.push(Routes.models),
            child: const Text(ChatStrings.otherModels),
          ),
        ],
      ),
    );
  }
}
