import 'package:flutter/material.dart';

const tabletBreakpoint = 720.0;
const desktopBreakpoint = 1100.0;

/// Bounds a whole panel. Use [ContentScrollFrame] for scrollable content.
class ContentFrame extends StatelessWidget {
  const ContentFrame({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: child,
      ),
    ),
  );
}

/// Centers a fixed-height panel without consuming the remaining vertical space.
class ContentWidth extends StatelessWidget {
  const ContentWidth({super.key, required this.child, this.maxWidth = 760});
  final Widget child;
  final double maxWidth;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: SizedBox(width: double.infinity, child: child),
    ),
  );
}

/// Keeps gutters inside the native scroll viewport, with centered content.
class ContentScrollFrame extends StatelessWidget {
  const ContentScrollFrame({
    super.key,
    required this.builder,
    this.maxWidth = 760,
    this.padding,
  });
  final Widget Function(BuildContext context, EdgeInsets padding) builder;
  final double maxWidth;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final safePadding = MediaQuery.paddingOf(context);
      final insets =
          padding ??
          EdgeInsets.only(top: safePadding.top, bottom: safePadding.bottom);
      final gutter = ((constraints.maxWidth - maxWidth) / 2).clamp(
        0.0,
        double.infinity,
      );
      return builder(
        context,
        EdgeInsets.fromLTRB(
          insets.left + gutter,
          insets.top,
          insets.right + gutter,
          insets.bottom,
        ),
      );
    },
  );
}

/// Touch-friendly sheets on phones, bounded dialogs on larger screens.
Future<T?> showAdaptiveSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  if (MediaQuery.sizeOf(context).width < tabletBreakpoint) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .9,
      ),
      builder: builder,
    );
  }
  return showDialog<T>(
    context: context,
    builder: (context) => Dialog(
      constraints: BoxConstraints(
        maxWidth: 560,
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 24),
        child: builder(context),
      ),
    ),
  );
}
