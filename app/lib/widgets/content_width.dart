import 'package:flutter/material.dart';

/// Constrains page content to a readable width, top-centered.
///
/// Applied consistently to the major screens; keeps desktop/Linux usable.
/// Never vertically centers or fixes the height of a scrolling page.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 600});

  static const double defaultMaxWidth = 600;

  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: child,
      ),
    );
  }
}
