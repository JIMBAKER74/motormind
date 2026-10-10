import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../advisor/display_agent.dart';
import '../advisor/display_rules.dart';
import '../chat/cards/card_shell.dart';
import '../chat/chat_strings.dart';
import 'search_service.dart';

/// The live filters as a card inside the conversation. It is app-owned and
/// bound to the search state, so it can never show a stale filter and the
/// model is never asked to render it. Each tap applies at once; the site row
/// chooses where to look. The display decision picks expanded, summary or
/// hidden; the person's own expand or collapse wins until a filter changes.
class SearchFiltersCard extends ConsumerWidget {
  const SearchFiltersCard({super.key});

  /// Price ceilings as chips: the rungs most used-car shoppers name first.
  static const priceCeilings = [25000, 35000, 50000, 75000];

  /// Mileage ceilings: under 50k reads as "like new", under 100k as "safe".
  static const mileageCeilings = [50000, 100000];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final q = search.query;
    final svc = ref.read(searchProvider.notifier);
    final theme = Theme.of(context);
    final mode = ref.watch(displayProvider).filters;
    return switch (mode) {
      // The key marks the slot, not a visible card, so tests can see that
      // the card is hidden rather than missing.
      FiltersCardMode.hidden => const SizedBox.shrink(key: Key('card-search_filters')),
      FiltersCardMode.summary => Card(
        key: const Key('card-search_filters'),
        child: ListTile(
          key: const Key('filters-summary'),
          dense: true,
          leading: const Icon(Icons.filter_alt_outlined),
          title: Text(
            '${q.describe()} · ${search.siteName}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const _SearchStatus(),
          trailing: const Icon(Icons.expand_more),
          onTap: () => svc.setExpanded(true),
        ),
      ),
      FiltersCardMode.expanded => CardShell(
        id: 'search_filters',
        padding: const EdgeInsets.all(12),
        children: [
          // The header carries the collapse control and the status, so it is
          // a child row rather than the shell's title.
          Row(
            children: [
              Expanded(child: Text(ChatStrings.filtersTitle, style: theme.textTheme.titleMedium)),
              if (!q.isEmpty)
                IconButton(
                  key: const Key('filters-collapse'),
                  tooltip: ChatStrings.collapse,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.expand_less),
                  onPressed: () => svc.setExpanded(false),
                ),
              const _SearchStatus(),
            ],
          ),
          const SizedBox(height: 6),
          _CeilingRow<String>(
            keyPrefix: 'body',
            anyLabel: ChatStrings.anyType,
            anySelected: q.bodyStyle == null,
            values: SearchQuery.bodyStyles,
            labelOf: (b) => SearchQuery.bodyStyleLabels[b]!,
            isSelected: (b) => q.bodyStyle == b,
            onSelect: (b) => svc.update({'body_style': b}),
          ),
          _CeilingRow<int>(
            keyPrefix: 'price',
            anyLabel: ChatStrings.anyPrice,
            anySelected: q.maxPrice == null,
            values: priceCeilings,
            labelOf: ChatStrings.underPrice,
            isSelected: (p) => q.maxPrice == p.toDouble(),
            onSelect: (p) => svc.update({'max_price': p}),
          ),
          _CeilingRow<int>(
            keyPrefix: 'miles',
            anyLabel: ChatStrings.anyMiles,
            anySelected: q.maxMileage == null,
            values: mileageCeilings,
            labelOf: ChatStrings.underMiles,
            isSelected: (m) => q.maxMileage == m,
            onSelect: (m) => svc.update({'max_mileage': m}),
          ),
          const Divider(height: 16),
          _ChipRow(
            leading: Text(ChatStrings.lookOn, style: theme.textTheme.labelMedium),
            chips: [
              for (final s in CuratedSites.all)
                _FilterChip(
                  key: Key('site-${s.id}'),
                  label: s.name,
                  selected: search.siteId == s.id,
                  onTap: () => svc.selectSite(s.id),
                ),
            ],
          ),
          if (search.note case final note?)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                note,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error),
              ),
            ),
        ],
      ),
    };
  }
}

/// "reading…" while a page is being read, then how many listings matched.
class _SearchStatus extends ConsumerWidget {
  const _SearchStatus();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final search = ref.watch(searchProvider);
    final text = search.applying
        ? ChatStrings.reading
        : switch (search.lastCount) {
            null => '',
            final n => ChatStrings.matchedCount(n),
          };
    return Text(
      text,
      key: const Key('search-status'),
      style: Theme.of(context).textTheme.labelSmall,
    );
  }
}

/// One filter field as a row of chips: an "any" chip (key `<prefix>-any`)
/// that clears it, then one chip per value (key `<prefix>-<value>`). Tapping
/// the selected value clears it too, so every chip is a toggle. [onSelect]
/// gets null for "any". [anySelected] is the field being unset, which is not
/// the same as no chip matching: the model can set a value the chips do not
/// offer, and then nothing in the row is selected.
class _CeilingRow<T> extends StatelessWidget {
  const _CeilingRow({
    required this.keyPrefix,
    required this.anyLabel,
    required this.anySelected,
    required this.values,
    required this.labelOf,
    required this.isSelected,
    required this.onSelect,
  });

  final String keyPrefix;
  final String anyLabel;
  final bool anySelected;
  final List<T> values;
  final String Function(T value) labelOf;
  final bool Function(T value) isSelected;
  final void Function(T? value) onSelect;

  @override
  Widget build(BuildContext context) => _ChipRow(
    chips: [
      _FilterChip(
        key: Key('$keyPrefix-any'),
        label: anyLabel,
        selected: anySelected,
        onTap: () => onSelect(null),
      ),
      for (final v in values)
        _FilterChip(
          key: Key('$keyPrefix-$v'),
          label: labelOf(v),
          selected: isSelected(v),
          onTap: () => onSelect(isSelected(v) ? null : v),
        ),
    ],
  );
}

class _ChipRow extends StatelessWidget {
  const _ChipRow({required this.chips, this.leading});

  final List<Widget> chips;
  final Widget? leading;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 6,
    runSpacing: 2,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [?leading, ...chips],
  );
}

/// One filter chip. A widget rather than a closure so Flutter can skip the
/// chips whose inputs did not change.
class _FilterChip extends StatelessWidget {
  const _FilterChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => FilterChip(
    label: Text(label),
    selected: selected,
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    labelStyle: Theme.of(context).textTheme.labelMedium,
    onSelected: (_) => onTap(),
  );
}
