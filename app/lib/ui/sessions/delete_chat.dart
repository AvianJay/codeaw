import 'package:flutter/material.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';

Future<bool> confirmDeleteChat(
  BuildContext context, {
  required String sessionId,
  required String title,
  bool desktopSync = false,
}) async {
  final state = AppScope.read(context);
  final client = state.client;
  final sessions = state.sessions;
  final hub = state.hub;
  if (client == null ||
      sessions == null ||
      !client.isOnline ||
      sessions.isDeleting(sessionId)) {
    return false;
  }
  final summary = sessions.byId(sessionId);
  final controller = hub?.peek(sessionId);
  if (controller?.running == true ||
      (summary != null &&
          (summary.state != 'idle' ||
              summary.pending > 0 ||
              summary.queued > 0))) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('請先停止執行中的聊天，再刪除')));
    return false;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('刪除聊天？'),
      content: Text(
        '要刪除「$title」嗎？\n\n聊天紀錄與手機快取會從 Codeaw 移除，無法復原。專案檔案與上傳檔案會保留。${desktopSync ? '\n\nCodex 桌面上的對話會保留。' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
            foregroundColor: Theme.of(context).colorScheme.onError,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('刪除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return false;
  // The confirmation belongs to this paired PC, even if the user switches hosts.
  if (!identical(state.client, client)) return false;
  try {
    await sessions.deleteSession(sessionId);
    await hub?.forget(sessionId);
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('已刪除聊天')));
    }
    return true;
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('無法刪除聊天：${error is RpcError ? error.detail : error}'),
        ),
      );
    }
    return false;
  }
}
