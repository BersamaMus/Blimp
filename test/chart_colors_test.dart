import 'dart:math' as math;

import 'package:blimp/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

/// WCAG contrast ratio between two opaque colors.
double contrast(Color a, Color b) {
  final (la, lb) = (a.computeLuminance(), b.computeLuminance());
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  // The stats charts use one hue, so colorblind separation between series
  // doesn't apply; what must hold is contrast against the surfaces they sit on.
  test('chart marks stand out from their card and the page (WCAG 3:1 for graphics)', () {
    for (final surface in [AppColors.surface, AppColors.background]) {
      expect(contrast(AppColors.accent, surface), greaterThanOrEqualTo(3), reason: '$surface');
    }
  });

  test('chart text is readable (WCAG 4.5:1 for labels and values)', () {
    expect(contrast(AppColors.textSecondary, AppColors.surface), greaterThanOrEqualTo(4.5));
    expect(contrast(const Color(0xFFFFFFFF), AppColors.surfaceHigh), greaterThanOrEqualTo(4.5));
  });

  test('recessive text is still readable (WCAG 4.5:1), on every surface', () {
    for (final surface in [AppColors.background, AppColors.surface, AppColors.sheet, AppColors.surfaceHigh]) {
      expect(contrast(AppColors.textTertiary, surface), greaterThanOrEqualTo(4.5), reason: '$surface');
    }
  });

  test('a selected column stands apart from the dimmed ones', () {
    final dimmed = Color.alphaBlend(AppColors.accent.withValues(alpha: 0.35), AppColors.surface);
    expect(contrast(AppColors.accent, dimmed), greaterThanOrEqualTo(2));
  });
}
