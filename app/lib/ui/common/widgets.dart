import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../app_state.dart';
import '../../data/bridge_client.dart';

String timeAgo(DateTime? t) {
  if (t == null) return '';
  final d = DateTime.now().difference(t.toLocal());
  if (d.inSeconds < 60) return '剛剛';
  if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
  if (d.inHours < 24) return '${d.inHours} 小時前';
  if (d.inDays < 7) return '${d.inDays} 天前';
  final l = t.toLocal();
  return '${l.year}/${l.month}/${l.day}';
}

String compactTokens(num n) {
  if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
  if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
  return '$n';
}

/// Thin strip under the app bar while the connection is not up.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final client = AppScope.of(context).client;
    if (client == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: client,
      builder: (context, _) {
        if (client.status == ConnStatus.online) return const SizedBox.shrink();
        final scheme = Theme.of(context).colorScheme;
        final connecting = client.status == ConnStatus.connecting;
        return Material(
          color: connecting ? scheme.secondaryContainer : scheme.errorContainer,
          child: InkWell(
            onTap: client.reconnectNow,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  if (connecting)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.cloud_off_rounded,
                      size: 16,
                      color: scheme.onErrorContainer,
                    ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      connecting
                          ? '連線中…'
                          : '離線${client.lastError != null ? '：${client.lastError}' : ''}（點一下重試）',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color: connecting
                            ? scheme.onSecondaryContainer
                            : scheme.onErrorContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Small colored dot + label for a session's turn state.
class StateBadge extends StatelessWidget {
  const StateBadge({
    super.key,
    required this.state,
    this.pending = 0,
    this.queued = 0,
  });
  final String state;
  final int pending;
  final int queued;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (Color color, String label) = switch (state) {
      'requires_action' => (
        Colors.orange,
        '待批准${pending > 1 ? ' ×$pending' : ''}',
      ),
      'running' => (scheme.primary, queued > 0 ? '執行中 · 排隊 $queued' : '執行中'),
      _ => (scheme.outline, ''),
    };
    if (label.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Picks a stable color per agent id.
Color agentColor(String agentId) {
  switch (agentId.trim().toLowerCase()) {
    case 'claude':
      return const Color(0xFFD97757);
    case 'codex':
      return const Color(0xFF10A37F);
    case 'grok':
    case 'xai':
      return const Color(0xFF7186A5);
    case 'kimi':
      return const Color(0xFF3B82F6);
    case 'hermes':
      return const Color(0xFFC58C32);
    case 'gemini':
      return const Color(0xFF8E75B2);
    case 'deepseek':
      return const Color(0xFF4D6BFE);
    case 'antigravity':
      return const Color(0xFF4285F4);
  }
  final h = agentId.codeUnits.fold<int>(7, (a, c) => (a * 31 + c) & 0xffff);
  return HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.55, 0.5).toColor();
}

class AgentAvatar extends StatelessWidget {
  const AgentAvatar({
    super.key,
    required this.agentId,
    this.size = 32,
    this.label,
  });
  final String agentId;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = agentColor(agentId);
    final text = (label ?? agentId).trim();
    final id = agentId.trim().toLowerCase();
    final asset = switch (id) {
      'grok' || 'xai' => 'assets/agents/grok.svg',
      'claude' ||
      'codex' ||
      'kimi' ||
      'hermes' ||
      'gemini' ||
      'deepseek' ||
      'antigravity' => 'assets/agents/$id.svg',
      _ => null,
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.withValues(
          alpha: Theme.of(context).brightness == Brightness.dark ? .18 : .09,
        ),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: c.withValues(alpha: .12)),
      ),
      child: asset == null
          ? Text(
              text.isEmpty ? '?' : text.characters.first.toUpperCase(),
              style: TextStyle(
                color: c,
                fontWeight: FontWeight.w700,
                fontSize: size * 0.45,
              ),
            )
          : Padding(
              padding: EdgeInsets.all(size * 0.18),
              child: SvgPicture.asset(
                asset,
                width: size * 0.64,
                height: size * 0.64,
                colorFilter: ColorFilter.mode(c, BlendMode.srcIn),
                semanticsLabel: text.isEmpty ? id : text,
              ),
            ),
    );
  }
}
