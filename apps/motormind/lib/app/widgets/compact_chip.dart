import 'package:flutter/material.dart';

/// A chip at compact density, the size every chip inside a card uses so a
/// row of them fits a phone. With [onPressed] it is an [ActionChip];
/// without, a plain [Chip] that only labels.
class CompactChip extends StatelessWidget {
  const CompactChip({super.key, required this.label, this.onPressed});

  final Widget label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => onPressed == null
      ? Chip(label: label, visualDensity: VisualDensity.compact)
      : ActionChip(label: label, visualDensity: VisualDensity.compact, onPressed: onPressed);
}
