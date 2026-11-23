import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../data/session_controller.dart';
import '../../data/timeline.dart';
import '../common/app_theme.dart';
import '../common/image_preview.dart';
import '../common/markdown_image.dart';
import '../common/widgets.dart';

/// Something an agent put into the chat with one of the bridge's own tools.
class AgentCardView extends StatelessWidget {
  const AgentCardView(this.item, {super.key, required this.controller});
  final CardItem item;
  final SessionController controller;

  @override
  Widget build(BuildContext context) => switch (item.kind) {
        'files' => _FilesCard(item, controller: controller),
        'notice' => _NoticeCard(item),
        // Quick replies sit above the composer; other kinds come from a newer bridge.
        _ => const SizedBox.shrink(),
      };
}

class _FilesCard extends StatelessWidget {
  const _FilesCard(this.item, {required this.controller});
  final CardItem item;
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final files = item.files;
    if (files.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final title = item.card['title'] as String?;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CodeawRadii.lg),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (title != null && title.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                child: Row(children: [
                  Icon(Icons.attach_file_rounded, size: 16, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(child: Text(title, style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: scheme.onSurface))),
                ]),
              ),
            for (final (i, file) in files.indexed) ...[
              if (i > 0) Divider(height: 1, indent: 62, endIndent: 14, color: scheme.outlineVariant.withValues(alpha: .6)),
              _SharedFile(file, controller: controller),
            ],
          ]),
        ),
      ),
    );
  }
}

/// One file on the bridge computer: an inline preview for images, and a row that opens it.
class _SharedFile extends StatelessWidget {
  const _SharedFile(this.file, {required this.controller});
  final Map<String, dynamic> file;
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final path = file['path'] as String;
    final name = file['name'] as String? ?? path.split(RegExp(r'[\\/]')).last;
    final size = file['size'];
    final caption = file['caption'] as String?;
    final mimeType = file['mimeType'] as String? ?? '';
    // The path is exact, so it is not parsed like a Markdown image source. SVG is not decodable here.
    final preview = mimeType.startsWith('image/') && mimeType != 'image/svg+xml'
        ? NetworkImage(controller.client.httpUri('/api/fs/raw', {'path': path}).toString(), headers: controller.client.authHeaders)
        : null;
    final detail = [
      if (size is num) formatBytes(size),
      if (caption != null && caption.isNotEmpty) caption,
    ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (preview != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DeferredImage(
              provider: preview,
              builder: (context) => ClipRRect(
                borderRadius: BorderRadius.circular(CodeawRadii.md),
                child: InkWell(
                  onTap: () => showImagePreview(context, preview),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: Image(
                      image: preview,
                      fit: BoxFit.contain,
                      semanticLabel: '$name，點擊放大',
                      // The row below still opens the file.
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      InkWell(
        onTap: () => context.push(Uri(path: '/file', queryParameters: {'path': path}).toString()),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(CodeawRadii.sm + 2),
              ),
              child: Icon(fileIcon(name), size: 19, color: scheme.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
                if (detail.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, height: 1.35, color: scheme.onSurfaceVariant)),
                  ),
              ]),
            ),
            const SizedBox(width: 6),
            Icon(Icons.chevron_right_rounded, size: 20, color: scheme.outline),
          ]),
        ),
      ),
    ]);
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard(this.item);
  final CardItem item;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = item.card['title'] as String?;
    final urgent = item.card['urgent'] == true;
    final accent = urgent ? scheme.error : scheme.primary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: .07),
          borderRadius: BorderRadius.circular(CodeawRadii.md),
          border: Border.all(color: accent.withValues(alpha: .2)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              urgent ? Icons.notification_important_outlined : Icons.notifications_none_rounded,
              size: 17,
              color: accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText.rich(
              TextSpan(children: [
                if (title != null && title.isNotEmpty) TextSpan(text: '$title\n', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: scheme.onSurface)),
                TextSpan(text: '${item.card['message'] ?? ''}'),
              ]),
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, height: 1.45),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Replies the agent offered for its last turn, above the composer. A tap sends one.
class SuggestedReplies extends StatelessWidget {
  const SuggestedReplies({super.key, required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    // They answer a finished turn; during one, a tap would be steered into it.
    if (controller.running || controller.waitingForDesktop) return const SizedBox.shrink();
    final replies = controller.timeline.suggestedReplies;
    if (replies.isEmpty) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return ConstrainedBox(
      // Long replies wrap; they never push the conversation off a phone screen.
      constraints: const BoxConstraints(maxHeight: 148),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            for (final reply in replies)
              Semantics(
                button: true,
                hint: '送出這則回覆',
                child: Material(
                  color: scheme.primary.withValues(alpha: .07),
                  shape: StadiumBorder(side: BorderSide(color: scheme.primary.withValues(alpha: .35))),
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => controller.send([
                      {'type': 'text', 'text': reply},
                    ]),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Text(
                        reply,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: scheme.primary, height: 1.3),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
