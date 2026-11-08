import 'package:flutter/material.dart';

import '../chat_state.dart';
import '../chat_strings.dart';
import 'card_shell.dart';

/// A question with a few answers, from the model's `present(choice)` or from
/// the app's own starters. Once answered it collapses to its question in
/// italics, so the transcript keeps the context without the buttons. The
/// escape is the conversation input, whose hint says so.
class ChoiceCard extends StatelessWidget {
  const ChoiceCard({super.key, required this.shown, required this.onChoice, this.onDismiss});

  final ShownComponent shown;

  /// Sets the question aside unanswered; null hides the control.
  final VoidCallback? onDismiss;

  /// Called with the option id and label; the service sends the label (plus
  /// any typed supplement) as the person's message.
  final void Function(String id, String label) onChoice;

  @override
  Widget build(BuildContext context) {
    final req = shown.request;
    final options = (req.props['options'] as List?)?.cast<Map>() ?? const [];
    if (shown.answered) return _AnsweredLine('${req.props['question'] ?? ''}', shown.dismissed);
    return CardShell(
      id: 'choice',
      title: '${req.props['question'] ?? req.title ?? ''}',
      onDismiss: onDismiss,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final o in options)
              ActionChip(
                key: Key('choice-${o['id']}'),
                label: Text('${o['label']}'),
                onPressed: () => onChoice('${o['id']}', '${o['label']}'),
              ),
          ],
        ),
      ],
    );
  }
}

/// What an answered prompt collapses to: its question in italics, so the
/// transcript keeps the context without the buttons; "set aside" when the
/// person dismissed it instead.
class _AnsweredLine extends StatelessWidget {
  const _AnsweredLine(this.question, this.dismissed);

  final String question;
  final bool dismissed;

  String get text => dismissed ? '$question (${ChatStrings.setAside})' : question;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(fontStyle: FontStyle.italic),
    ),
  );
}

/// A short form (one to six fields) for numbers the model needs before a
/// calculation. The fields stay editable until submitted; the filled
/// values are sent as one labeled sentence so the model reads them as the
/// person's own inputs.
class FormCard extends StatefulWidget {
  const FormCard({super.key, required this.shown, required this.onSubmit, this.onDismiss});

  final ShownComponent shown;
  final void Function(String text) onSubmit;

  /// Sets the form aside unsent; null hides the control.
  final VoidCallback? onDismiss;

  @override
  State<FormCard> createState() => _FormCardState();
}

class _FormCardState extends State<FormCard> {
  final Map<String, TextEditingController> _controllers = {};

  List<Map> get _fields => (widget.shown.request.props['fields'] as List?)?.cast<Map>() ?? const [];

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// "Label: value; Label: value" for the fields that were filled in.
  String _sentence() => [
    for (final f in _fields)
      if ((_controllers['${f['id']}']?.text ?? '').trim().isNotEmpty)
        '${f['label']}: ${_controllers['${f['id']}']!.text.trim()}',
  ].join('; ');

  @override
  Widget build(BuildContext context) {
    final title =
        '${widget.shown.request.props['title'] ?? widget.shown.request.title ?? 'A few details'}';
    if (widget.shown.answered) return _AnsweredLine(title, widget.shown.dismissed);
    return CardShell(
      id: 'input_form',
      title: title,
      onDismiss: widget.onDismiss,
      children: [
        for (final f in _fields)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: TextField(
              key: Key('field-${f['id']}'),
              controller: _controllers.putIfAbsent('${f['id']}', TextEditingController.new),
              keyboardType: f['type'] == 'text'
                  ? TextInputType.text
                  : const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: '${f['label']}',
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        const SizedBox(height: 8),
        FilledButton(
          key: const Key('form-submit'),
          onPressed: () {
            final text = _sentence();
            widget.onSubmit(text.isEmpty ? 'I would rather explain.' : text);
          },
          child: const Text('Use these'),
        ),
      ],
    );
  }
}
