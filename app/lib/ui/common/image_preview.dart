import 'package:flutter/material.dart';

Future<void> showImagePreview(BuildContext context, ImageProvider provider) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<void>(
    context: context,
    builder: (_) => _ImagePreview(provider: provider),
  );
}

class _ImagePreview extends StatefulWidget {
  const _ImagePreview({required this.provider});
  final ImageProvider provider;
  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  final _transform = TransformationController();
  Offset _tapPosition = Offset.zero;

  void _toggleZoom() {
    _transform.value = _transform.value.getMaxScaleOnAxis() > 1
        ? Matrix4.identity()
        : (Matrix4.diagonal3Values(2, 2, 1)
            ..setTranslationRaw(-_tapPosition.dx, -_tapPosition.dy, 0));
  }

  @override
  void dispose() {
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog.fullscreen(
    child: Scaffold(
      appBar: AppBar(
        title: const Text('圖片'),
        leading: IconButton(
          tooltip: '關閉',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            tooltip: '放大或還原',
            icon: const Icon(Icons.zoom_in_rounded),
            onPressed: () {
              final size = MediaQuery.sizeOf(context);
              _tapPosition = Offset(
                size.width / 2,
                (size.height - kToolbarHeight) / 2,
              );
              _toggleZoom();
            },
          ),
          IconButton(
            tooltip: '重設縮放',
            icon: const Icon(Icons.fit_screen_rounded),
            onPressed: () => _transform.value = Matrix4.identity(),
          ),
        ],
      ),
      body: SafeArea(
        child: GestureDetector(
          onDoubleTapDown: (details) => _tapPosition = details.localPosition,
          onDoubleTap: _toggleZoom,
          child: InteractiveViewer(
            transformationController: _transform,
            minScale: 1,
            maxScale: 8,
            child: SizedBox.expand(
              child: Image(
                image: widget.provider,
                fit: BoxFit.contain,
                semanticLabel: '圖片，可雙指縮放、拖曳或點兩下放大',
                errorBuilder: (_, _, _) => const Center(child: Text('無法載入圖片')),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
