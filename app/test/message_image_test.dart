import 'dart:convert';

import 'package:codeaw/data/timeline.dart';
import 'package:codeaw/ui/chat/items.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const png =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGPgn9v1HwAEKwI2+WpYHgAAAABJRU5ErkJggg==';

void main() {
  testWidgets(
    'own uploaded image opens, zooms, pans, resets and closes on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final m = MessageItem('image', MessageRole.user, 'image')
        ..parts.add({'type': 'image', 'data': png, 'mimeType': 'image/png'});
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: UserMessageView(m))),
      );
      await tester.runAsync(
        () => precacheImage(
          MemoryImage(base64Decode(png)),
          tester.element(find.byType(BlockImage)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      final viewer = tester.widget<InteractiveViewer>(
        find.byType(InteractiveViewer),
      );
      final transform = viewer.transformationController!;
      expect(viewer.maxScale, 8);
      final center = tester.getCenter(find.byType(InteractiveViewer));
      await tester.tapAt(center);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(center);
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), 2);
      final before = transform.value.clone();
      await tester.drag(find.byType(InteractiveViewer), const Offset(40, 0));
      await tester.pumpAndSettle();
      expect(transform.value, isNot(equals(before)));
      await tester.tap(find.byTooltip('重設縮放'));
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), 1);
      await tester.tap(find.byTooltip('放大或還原'));
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), 2);
      await tester.tap(find.byTooltip('放大或還原'));
      await tester.pumpAndSettle();
      expect(transform.value.getMaxScaleOnAxis(), 1);
      await tester.tap(find.byTooltip('關閉'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byType(UserMessageView), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
