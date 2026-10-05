import 'package:flutter/material.dart';

Color cpaQuotaColor(BuildContext context, double? remaining) {
  final theme = Theme.of(context);
  if (remaining == null) return theme.colorScheme.outline;
  final dark = theme.brightness == Brightness.dark;
  if (remaining < 20) {
    return dark ? const Color(0xFFF87171) : const Color(0xFFDC2626);
  }
  if (remaining < 50) {
    return dark ? const Color(0xFFFBBF24) : const Color(0xFFB77900);
  }
  return dark ? const Color(0xFF4ADE80) : const Color(0xFF15803D);
}
