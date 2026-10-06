import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../app_state.dart';
import '../../data/bridge_client.dart';
import 'image_preview.dart';

/// Resolve paths using the bridge's OS conventions, not the phone's.
String? markdownImagePath(String source, {String? basePath}) {
  final windowsPath = RegExp(r'^[a-zA-Z]:[\\/]|^\\\\');
  // File links may use a URL-style slash before a Windows drive.
  if (RegExp(r'^/[a-zA-Z]:[\\/]').hasMatch(source)) {
    source = source.substring(1);
  }
  if (windowsPath.hasMatch(source)) {
    return p.windows.normalize(Uri.decodeFull(source));
  }
  final uri = Uri.tryParse(source.replaceAll('\\', '/'));
  if (uri == null) return null;
  if (uri.scheme == 'file') {
    if (uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return null;
    }
    final windows =
        RegExp(r'^/[a-zA-Z]:/').hasMatch(uri.path) || uri.host.isNotEmpty;
    return uri.toFilePath(windows: windows);
  }
  if (uri.hasScheme || uri.hasAuthority) return null;
  final path = Uri.decodeComponent(uri.path);
  if (p.posix.isAbsolute(path)) return p.posix.normalize(path);
  if (basePath == null || basePath.isEmpty) return null;
  final paths = windowsPath.hasMatch(basePath) ? p.windows : p.posix;
  return paths.normalize(paths.join(basePath, path));
}

/// Only bridge-hosted resources receive the device's credentials.
ImageProvider? markdownImageProvider(
  String source, {
  BridgeClient? client,
  String? basePath,
}) {
  try {
    if (source.startsWith('data:')) {
      final data = UriData.parse(source);
      return data.mimeType.startsWith('image/')
          ? MemoryImage(data.contentAsBytes())
          : null;
    }
    final uri = Uri.tryParse(source);
    if (uri != null && (uri.scheme == 'https' || uri.scheme == 'http')) {
      return NetworkImage(source);
    }
    if (source.startsWith('//')) return NetworkImage('https:$source');
    if (client == null) return null;
    if (RegExp(r'^codeaw-blob:[0-9a-f]{64}$').hasMatch(source)) {
      return NetworkImage(
        client.httpUri('/api/blobs/${source.substring(12)}').toString(),
        headers: client.authHeaders,
      );
    }
    final path = markdownImagePath(source, basePath: basePath);
    if (path == null || path.isEmpty) return null;
    return NetworkImage(
      client.httpUri('/api/fs/raw', {'path': path}).toString(),
      headers: client.authHeaders,
    );
  } on FormatException {
    return null;
  } on ArgumentError {
    return null;
  } on UnsupportedError {
    return null;
  }
}

class MarkdownImage extends StatelessWidget {
  const MarkdownImage({
    super.key,
    required this.source,
    this.client,
    this.basePath,
    this.width,
    this.height,
  });
  final String source;
  final BridgeClient? client;
  final String? basePath;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final provider = markdownImageProvider(
      source,
      client: client,
      basePath: basePath,
    );
    if (provider == null) return const _ImageFailure();
    return DeferredImage(
      provider: provider,
      builder: (context) => LayoutBuilder(
        builder: (context, constraints) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth,
              maxHeight: 360,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: InkWell(
                onTap: () => showImagePreview(context, provider),
                child: Image(
                  image: provider,
                  width: width,
                  height: height,
                  fit: BoxFit.contain,
                  semanticLabel: '圖片，點擊放大',
                  loadingBuilder: (_, child, progress) => progress == null
                      ? child
                      : const SizedBox(
                          width: 48,
                          height: 48,
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                  errorBuilder: (_, _, _) => const _ImageFailure(),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// With data saver on, downloaded images wait for a tap unless already in memory.
class DeferredImage extends StatefulWidget {
  const DeferredImage({super.key, required this.provider, required this.builder});
  final ImageProvider provider;
  final WidgetBuilder builder;

  @override
  State<DeferredImage> createState() => _DeferredImageState();
}

class _DeferredImageState extends State<DeferredImage> {
  bool _requested = false;

  @override
  Widget build(BuildContext context) {
    final saver = context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier?.dataSaver ?? false;
    final provider = widget.provider;
    if (_requested || !saver || provider is! NetworkImage || PaintingBinding.instance.imageCache.containsKey(provider)) {
      return widget.builder(context);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: OutlinedButton.icon(
        onPressed: () => setState(() => _requested = true),
        icon: const Icon(Icons.image_outlined, size: 18),
        label: const Text('點擊載入圖片'),
      ),
    );
  }
}

class _ImageFailure extends StatelessWidget {
  const _ImageFailure();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.broken_image_outlined,
          size: 20,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(width: 6),
        const Flexible(child: Text('無法載入圖片')),
      ],
    ),
  );
}
