import 'package:flutter/material.dart';

/// Adaptive label/value row for dense read-only information.
///
/// Side-by-side on wide layouts; stacked on narrow layouts or at large text
/// scales so neither the label nor the value is clipped away.
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.labelWidth = 128,
    this.stackBelow = 360,
  });

  final String label;
  final String value;
  final double labelWidth;
  final double stackBelow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final textScale = MediaQuery.textScalerOf(context).scale(1);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stack = constraints.maxWidth < stackBelow || textScale > 1.3;
          if (stack) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: labelStyle),
                const SizedBox(height: 2),
                Text(value, style: theme.textTheme.bodyMedium),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                  width: labelWidth, child: Text(label, style: labelStyle)),
              Expanded(child: Text(value)),
            ],
          );
        },
      ),
    );
  }
}
