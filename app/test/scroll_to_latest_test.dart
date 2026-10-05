import 'package:codeaw/ui/chat/scroll_to_latest.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'scroll button appears away from latest, preserves position while streaming and returns to zero',
    (tester) async {
      var rows = 80;
      late StateSetter update;
      ScrollController? scroll;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return ScrollToLatest(
                  builder: (context, controller) {
                    scroll = controller;
                    return ListView.builder(
                      controller: controller,
                      reverse: true,
                      itemCount: rows,
                      itemExtent: 60,
                      itemBuilder: (context, index) => Text('message $index'),
                    );
                  },
                );
              },
            ),
          ),
        ),
      );
      expect(find.byTooltip('捲到最底'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(find.byTooltip('捲到最底'), findsOneWidget);
      final readingOffset = scroll!.offset;
      update(() => rows += 2);
      await tester.pump();
      expect(scroll!.offset, readingOffset);
      await tester.tap(find.byTooltip('捲到最底'));
      await tester.pumpAndSettle();
      expect(scroll!.offset, closeTo(0, .1));
      expect(find.byTooltip('捲到最底'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
