import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';

/// The frame every presented card shares, and the one owner of the
/// `card-<id>` widget key convention: an optional title, the body, and for
/// finance cards the assumptions the calculation leaned on (collapsed) plus
/// the estimates-only line that no finance card may drop.
class CardShell extends StatelessWidget {
  const CardShell({
    super.key,
    required this.id,
    required this.children,
    this.title,
    this.padding = const EdgeInsets.all(14),
    this.assumptions,
  });

  /// The registry component id; becomes the widget key tests look for.
  final String id;

  /// The heading line; null when the first child draws its own header row.
  final String? title;
  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  /// Non-null marks a finance card: the assumptions tile (when any) and the
  /// estimates-only line appear. Prompts and listings pass nothing.
  final List<Map<String, Object?>>? assumptions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final assumptions = this.assumptions;
    return Card(
      key: Key('card-$id'),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title case final title?) ...[
              Text(title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
            ],
            ...children,
            if (assumptions != null && assumptions.isNotEmpty) ...[
              const SizedBox(height: 6),
              Theme(
                data: theme.copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    'Assumptions (${assumptions.length})',
                    style: theme.textTheme.labelLarge,
                  ),
                  children: [
                    for (final a in assumptions)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text('${a['description']}'),
                        subtitle: Text('${a['value']} · ${a['source']} · as of ${a['asOf']}'),
                      ),
                  ],
                ),
              ),
            ],
            if (assumptions != null) ...[
              const SizedBox(height: 4),
              Text(Disclosures.estimatesOnly.short, style: theme.textTheme.labelSmall),
            ],
          ],
        ),
      ),
    );
  }
}

/// One label-and-value line in a finance card. [valueKey] names the output
/// field so tests can find the value; [emphasis] is the model's highlight.
class ValueRow extends StatelessWidget {
  const ValueRow(
    this.label,
    this.value, {
    super.key,
    this.valueKey,
    this.emphasis = false,
    this.color,
  });

  final String label;
  final String value;
  final String? valueKey;
  final bool emphasis;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          Text(
            value,
            key: valueKey == null ? null : Key('out-$valueKey'),
            style: emphasis
                ? theme.textTheme.titleMedium?.copyWith(
                    color: color ?? theme.colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  )
                : theme.textTheme.bodyMedium?.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}

/// A small heading between groups of rows ("What you pay", "The loan").
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 2),
    child: Text(text, style: Theme.of(context).textTheme.labelLarge),
  );
}
