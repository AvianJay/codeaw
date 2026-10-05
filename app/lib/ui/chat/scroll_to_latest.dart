import 'package:flutter/material.dart';

/// Chat lists are reversed, so zero is the latest message. Keeps the user's
/// scroll offset while new messages stream and exposes a reachable 48px target.
class ScrollToLatest extends StatefulWidget {
  const ScrollToLatest({super.key, required this.builder});
  final Widget Function(BuildContext, ScrollController) builder;

  @override
  State<ScrollToLatest> createState() => _ScrollToLatestState();
}

class _ScrollToLatestState extends State<ScrollToLatest> {
  final _scroll = ScrollController();
  bool _away = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_changed);
  }

  void _changed() {
    final away = _scroll.hasClients && _scroll.offset > 180;
    if (_away != away) setState(() => _away = away);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: widget.builder(context, _scroll)),
      if (_away)
        Positioned(
          right: 16,
          bottom: 12,
          child: SizedBox(
            width: 48,
            height: 48,
            child: FloatingActionButton.small(
              heroTag: null,
              tooltip: '捲到最底',
              onPressed: () => _scroll.animateTo(
                0,
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
              ),
              child: const Icon(Icons.arrow_downward_rounded),
            ),
          ),
        ),
    ],
  );
}
