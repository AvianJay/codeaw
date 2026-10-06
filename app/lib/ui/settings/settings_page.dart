import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';
import 'live_activity_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? _ntfy;

  @override
  void initState() {
    super.initState();
    _loadNtfy();
  }

  Future<void> _loadNtfy() async {
    try {
      final r =
          await AppScope.read(context).client!.request('_codeaw/notify/info')
              as Map<String, dynamic>;
      if (mounted) setState(() => _ntfy = r);
    } catch (_) {}
  }

  Future<void> _restartAgent(String id) async {
    final client = AppScope.read(context).client!;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await client.request('_codeaw/agents/restart', {'agentId': id});
      final r =
          await client.request('_codeaw/agents/list') as Map<String, dynamic>;
      messenger.showSnackBar(
        SnackBar(
          content: Text('已重新啟動（${(r['agents'] as List).length} 個 agent）'),
        ),
      );
    } on RpcError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.detail)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final host = state.host;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('設定')),
      body: client == null || host == null
          ? const SizedBox.shrink()
          : ListenableBuilder(
              listenable: client,
              builder: (context, _) => ContentScrollFrame(
                builder: (context, padding) => ListView(
                  padding: padding,
                  children: [
                    const _Section('外觀'),
                    ListTile(
                      leading: const Icon(Icons.contrast_rounded),
                      title: const Text('顯示主題'),
                      trailing: DropdownButtonHideUnderline(
                        child: DropdownButton<ThemeMode>(
                          value: state.themeMode,
                          items: const [
                            DropdownMenuItem(
                              value: ThemeMode.system,
                              child: Text('跟隨系統'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.light,
                              child: Text('淺色'),
                            ),
                            DropdownMenuItem(
                              value: ThemeMode.dark,
                              child: Text('深色'),
                            ),
                          ],
                          onChanged: (mode) async {
                            if (mode == null) return;
                            final messenger = ScaffoldMessenger.of(context);
                            try {
                              await state.setThemeMode(mode);
                            } catch (_) {
                              messenger.showSnackBar(
                                const SnackBar(content: Text('無法儲存外觀設定')),
                              );
                            }
                          },
                        ),
                      ),
                    ),
                    const _Section('用量與帳號'),
                    ListTile(
                      leading: Icon(
                        Icons.donut_large_rounded,
                        color: scheme.primary,
                      ),
                      title: const Text('CPA 用量與額度'),
                      subtitle: const Text('Codex、Claude、Grok · 重置時間與剩餘額度'),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => context.push('/usage'),
                    ),
                    const _Section('App 更新'),
                    ListenableBuilder(
                      listenable: state.updater,
                      builder: (context, _) => ListTile(
                        leading: Badge(
                          isLabelVisible: state.updater.updateAvailable,
                          child: const Icon(Icons.system_update_rounded),
                        ),
                        title: Text(
                          state.updater.updateAvailable
                              ? '有可用的 App 更新'
                              : '檢查 App 更新',
                        ),
                        subtitle: Text(
                          '${state.updater.installedVersion} · ${state.updater.channel.name}',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push('/updates'),
                      ),
                    ),
                    const _Section('電腦'),
                    ListTile(
                      leading: const Icon(Icons.computer_rounded),
                      title: Text(client.bridgeHost ?? host.name),
                      subtitle: Text(
                        '${client.status == ConnStatus.online ? '已連線' : '未連線'} · ${client.activeUrl ?? host.urls.first}',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.refresh_rounded),
                        onPressed: client.reconnectNow,
                      ),
                    ),
                    ListTile(
                      leading: const Icon(Icons.badge_outlined),
                      title: Text('這台裝置：${host.deviceName}'),
                      subtitle: Text(
                        '裝置 ID ${host.deviceId}（在電腦上用 codeaw-bridge revoke 撤銷）',
                      ),
                    ),
                    const _Section('Agents'),
                    for (final a in client.agents)
                      ListTile(
                        leading: AgentAvatar(agentId: a.id, label: a.name),
                        title: Text(
                          '${a.name}${a.version != null ? ' ${a.version}' : ''}',
                        ),
                        subtitle: Text(
                          switch (a.status) {
                            'ready' => '執行中${a.steering ? ' · 支援回合中插話' : ''}',
                            'error' => '錯誤：${a.error ?? ''}',
                            'starting' => '啟動中',
                            _ => '未啟動（用到時自動啟動）',
                          },
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: a.status == 'error' ? scheme.error : null,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: '重新啟動',
                          icon: const Icon(Icons.restart_alt_rounded),
                          onPressed: () => _restartAgent(a.id),
                        ),
                      ),
                    if (state.liveActivity.supported) ...[
                      const _Section('即時動態'),
                      LiveActivitySettings(controller: state.liveActivity),
                    ],
                    const _Section('推播通知（App 沒開時）'),
                    if (_ntfy == null)
                      const ListTile(title: Text('讀取中…'))
                    else if (_ntfy!['enabled'] != true)
                      const ListTile(
                        leading: Icon(Icons.notifications_off_outlined),
                        title: Text('bridge 沒有設定 ntfy'),
                        subtitle: Text(
                          '在電腦的 ~/.codeaw/config.yaml 加入 notifications.ntfy 後重啟 bridge',
                        ),
                      )
                    else ...[
                      ListTile(
                        leading: const Icon(
                          Icons.notifications_active_outlined,
                        ),
                        title: Text('ntfy topic：${_ntfy!['topic']}'),
                        subtitle: Text(
                          '${_ntfy!['server']}\n安裝 ntfy App 並訂閱這個 topic，App 沒開時也能收到「需要批准 / 已完成」',
                        ),
                        isThreeLine: true,
                        onTap: () => Clipboard.setData(
                          ClipboardData(text: '${_ntfy!['topic']}'),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          children: [
                            OutlinedButton.icon(
                              icon: const Icon(
                                Icons.open_in_new_rounded,
                                size: 18,
                              ),
                              label: const Text('在 ntfy App 訂閱'),
                              onPressed: () {
                                final server = Uri.parse('${_ntfy!['server']}');
                                launchUrl(
                                  Uri.parse(
                                    'ntfy://${server.host}/${_ntfy!['topic']}',
                                  ),
                                  mode: LaunchMode.externalApplication,
                                );
                              },
                            ),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.send_rounded, size: 18),
                              label: const Text('傳送測試'),
                              onPressed: () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final r =
                                    await client.request('_codeaw/notify/test')
                                        as Map<String, dynamic>;
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      r['sent'] == true
                                          ? '已送出'
                                          : '送出失敗，請看 bridge 的紀錄',
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                    const _Section('其他'),
                    ListTile(
                      leading: const Icon(Icons.history_rounded),
                      title: const Text('清除這台電腦的本機聊天快取'),
                      subtitle: const Text('重開 App 先顯示已保存的歷史，再同步新訊息。只清除本機資料。'),
                      onTap: () async {
                        state.sessions?.discardPendingCache();
                        await state.hub?.clearCache();
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已清除本機聊天快取')),
                          );
                        }
                      },
                    ),
                    if (!kIsWeb)
                      ListTile(
                        leading: const Icon(Icons.notifications_outlined),
                        title: const Text('允許 App 通知'),
                        subtitle: const Text('App 在背景但仍連線時，用手機通知提醒'),
                        onTap: () => state.notifier.requestPermission(),
                      ),
                    ListTile(
                      leading: Icon(
                        Icons.link_off_rounded,
                        color: scheme.error,
                      ),
                      title: Text(
                        '取消配對',
                        style: TextStyle(color: scheme.error),
                      ),
                      onTap: () async {
                        final ok = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const Text('取消配對？'),
                            content: Text(
                              '這台裝置會忘記「${host.name}」的連線資訊，之後需要重新配對。其他電腦的配對會保留。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const Text('取消'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const Text('確定'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await state.forget();
                          if (context.mounted) {
                            context.go(state.paired ? '/' : '/pair');
                          }
                        }
                      },
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 18, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelLarge?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}
