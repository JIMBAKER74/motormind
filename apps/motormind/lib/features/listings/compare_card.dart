import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/compact_chip.dart';
import '../chat/cards/card_shell.dart';
import '../chat/cards/formatting.dart';
import '../chat/chat_service.dart';
import '../chat/chat_strings.dart';
import '../chat/turn_stats.dart';
import 'listing_cache.dart';

/// Two or three listings side by side, the component the model chooses
/// when the person has opened more than one car (`vehicle_compare`). The
/// numbers come from the listings result it names, never from the model;
/// the model only picks which listings (`props.ids`).
class CompareCard extends ConsumerWidget {
  const CompareCard({super.key, required this.shown});

  final ShownComponent shown;

  /// Photo height in a column; three columns share a phone's width.
  static const _photoHeight = 72.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final ids = (shown.request.props['ids'] as List?)?.cast<String>() ?? const [];
    final all = listingsOf(shown.result);
    final picked = [for (final id in ids) ...all.where((l) => l.id == id)];
    final photo = ref.watch(listingPhotoProvider);
    String row(String? v) => v ?? '–';
    return CardShell(
      id: 'vehicle_compare',
      title: shown.request.title ?? ChatStrings.compareTitle,
      children: [
        if (picked.length < 2)
          Text(ChatStrings.compareMissing, style: theme.textTheme.bodySmall)
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final l in picked)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      key: Key('compare-${l.id}'),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: SizedBox(
                            height: _photoHeight,
                            width: double.infinity,
                            child: l.imageUrl != null && l.imageUrl!.startsWith('https://')
                                ? photo(l.imageUrl!, height: _photoHeight)
                                : ColoredBox(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.directions_car_outlined),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          l.title,
                          style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(row(l.price == null ? null : money(l.price, cents: false))),
                        Text(
                          row(l.mileage == null ? null : '${thousands(l.mileage!)} mi'),
                          style: theme.textTheme.bodySmall,
                        ),
                        Text(row(l.year?.toString()), style: theme.textTheme.bodySmall),
                        const SizedBox(height: 4),
                        CompactChip(
                          key: Key('compare-cost-${l.id}'),
                          label: const Text('Monthly cost?'),
                          onPressed: () => ref
                              .read(chatServiceProvider.notifier)
                              .send(
                                ChatStrings.monthlyCostOf(l.title),
                                trigger: TurnTrigger.tileCost,
                                detail: 'compare ${l.id}',
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
