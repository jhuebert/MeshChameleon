import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/theme/app_theme.dart';

double contrast(Color a, Color b) {
  final first = a.computeLuminance();
  final second = b.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}

void main() {
  test('primary actions and text contrast against their surfaces', () {
    for (final theme in [
      MeshChameleonTheme.light(),
      MeshChameleonTheme.dark()
    ]) {
      final colors = theme.colorScheme;
      for (final surface in [colors.surface, colors.surfaceContainerLow]) {
        expect(contrast(colors.primary, surface), greaterThanOrEqualTo(4.5));
        expect(contrast(colors.onSurface, surface), greaterThanOrEqualTo(4.5));
        expect(contrast(colors.onSurfaceVariant, surface),
            greaterThanOrEqualTo(4.5));
      }
      expect(contrast(colors.onPrimary, colors.primary),
          greaterThanOrEqualTo(4.5));
      expect(contrast(colors.onPrimaryContainer, colors.primaryContainer),
          greaterThanOrEqualTo(4.5));
    }
  });
}
