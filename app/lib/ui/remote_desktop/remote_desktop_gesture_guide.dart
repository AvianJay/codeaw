import 'package:flutter/material.dart';

class RemoteDesktopGestureGuide extends StatelessWidget {
  const RemoteDesktopGestureGuide({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.primaryContainer,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Icon(
                    Icons.touch_app_rounded,
                    color: colors.onPrimaryContainer,
                    size: 28,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '把手機當作觸控板',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '在畫面上滑動手指來移動游標，再用手勢點擊、捲動與拖曳。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            DecoratedBox(
              decoration: BoxDecoration(
                color: colors.surfaceContainerLow,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _GestureRow(
                      icon: Icons.swipe_rounded,
                      title: '單指滑動',
                      description: '移動游標',
                    ),
                    _GestureRow(
                      icon: Icons.touch_app_outlined,
                      title: '點一下',
                      description: '滑鼠左鍵；連點兩下就是雙擊',
                    ),
                    _GestureRow(
                      icon: Icons.mouse_outlined,
                      title: '兩指點一下',
                      description: '滑鼠右鍵',
                    ),
                    _GestureRow(
                      icon: Icons.open_with_rounded,
                      title: '兩指上下左右滑',
                      description: '垂直或水平捲動',
                    ),
                    _GestureRow(
                      icon: Icons.pan_tool_alt_outlined,
                      title: '長按',
                      description: '持續按住左鍵，放開才鬆開',
                    ),
                    _GestureRow(
                      icon: Icons.pan_tool_outlined,
                      title: '長按後滑動',
                      description: '拖曳視窗或選取文字',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '畫質與控制權限會自動調整。鍵盤、螢幕選擇與這份教學，都在右上角的三點選單。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              child: const Text('開始操控'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GestureRow extends StatelessWidget {
  const _GestureRow({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, size: 21, color: colors.primary),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
