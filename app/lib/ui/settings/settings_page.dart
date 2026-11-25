import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../common/adaptive.dart';
import '../common/app_theme.dart';
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
    unawaited(AppScope.read(context).androidLiveActivity.refreshSupport());
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
                    const _Section('一般'),
                    _Group([
                      ListTile(
                        leading: const Icon(Icons.contrast_rounded),
                        title: const Text('顯示主題'),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<ThemeMode>(
                            value: state.themeMode,
                            borderRadius: BorderRadius.circular(CodeawRadii.md),
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
                      SwitchListTile(
                        secondary: const Icon(Icons.data_saver_on_rounded),
                        title: const Text('節省數據'),
                        subtitle: const Text('圖片與大型輸出點開才載入'),
                        value: state.dataSaver,
                        onChanged: (enabled) async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await state.setDataSaver(enabled);
                          } catch (_) {
                            messenger.showSnackBar(
                              const SnackBar(content: Text('無法儲存數據用量設定')),
                            );
                          }
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.donut_large_rounded),
                        title: const Text('用量與額度'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => context.push('/usage'),
                      ),
                      ListenableBuilder(
                        listenable: state.updater,
                        builder: (context, _) => ListTile(
                          leading: Badge(
                            isLabelVisible: state.updater.updateAvailable,
                            child: const Icon(Icons.system_update_rounded),
                          ),
                          title: Text(
                            state.updater.updateAvailable ? '有可用的更新' : 'App 更新',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (state.updater.installed != null)
                                Text(
                                  state.updater.installedVersion,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: scheme.outline,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              const SizedBox(width: 4),
                              const Icon(Icons.chevron_right_rounded),
                            ],
                          ),
                          onTap: () => context.push('/updates'),
                        ),
                      ),
                    ]),
                    const _Section('電腦'),
                    _Group([
                      ListTile(
                        leading: const Icon(Icons.computer_rounded),
                        title: Text(client.bridgeHost ?? host.name),
                        subtitle: Text(
                          '${client.status == ConnStatus.online ? '已連線' : '未連線'} · ${client.activeUrl ?? host.urls.first}',
                        ),
                        trailing: IconButton(
                          tooltip: '重新連線',
                          icon: const Icon(Icons.refresh_rounded),
                          onPressed: client.reconnectNow,
                        ),
                      ),
                      ListTile(
                        leading: const Icon(Icons.badge_outlined),
                        title: Text('這台裝置：${host.deviceName}'),
                        subtitle: Text('裝置 ID ${host.deviceId}'),
                      ),
                    ]),
                    if (client.agents.isNotEmpty) ...[
                      const _Section('Agents'),
                      _Group([
                        for (final a in client.agents)
                          ListTile(
                            // The avatar is wider than an icon; the names still
                            // line up with the rows of the other groups.
                            horizontalTitleGap: 8,
                            leading: AgentAvatar(agentId: a.id, label: a.name),
                            title: Text(
                              '${a.name}${a.version != null ? ' ${a.version}' : ''}',
                            ),
                            subtitle: Text(
                              switch (a.status) {
                                'ready' => '執行中',
                                'error' => '錯誤：${a.error ?? ''}',
                                'starting' => '啟動中',
                                _ => '用到時啟動',
                              },
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: a.status == 'error'
                                    ? scheme.error
                                    : null,
                              ),
                            ),
                            trailing: IconButton(
                              tooltip: '重新啟動',
                              icon: const Icon(Icons.restart_alt_rounded),
                              onPressed: () => _restartAgent(a.id),
                            ),
                          ),
                      ]),
                    ],
                    if (state.liveActivity.supported) ...[
                      const _Section('即時動態'),
                      _Group([
                        LiveActivitySettings(controller: state.liveActivity),
                      ]),
                    ],
                    // Nothing to show on the web until the bridge has answered.
                    if (!kIsWeb || _ntfy != null) ...[
                      const _Section('通知'),
                      _Group([
                        if (!kIsWeb)
                          ListTile(
                            leading: const Icon(Icons.notifications_outlined),
                            title: const Text('允許 App 通知'),
                            subtitle: const Text('App 在背景時提醒'),
                            onTap: () => state.notifier.requestPermission(),
                          ),
                        if (_ntfy case final ntfy? when ntfy['enabled'] != true)
                          const ListTile(
                            leading: Icon(Icons.notifications_off_outlined),
                            title: Text('App 關閉時的推播未設定'),
                            subtitle: Text(
                              '在電腦的 ~/.codeaw/config.yaml 加入 notifications.ntfy，再重啟 bridge',
                            ),
                          ),
                        // One entry, so no hairline parts the topic from its buttons.
                        if (_ntfy case final ntfy? when ntfy['enabled'] == true)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              ListTile(
                                leading: const Icon(
                                  Icons.notifications_active_outlined,
                                ),
                                title: Text('ntfy topic：${ntfy['topic']}'),
                                subtitle: Text(
                                  'App 關閉時的推播 · ${ntfy['server']}',
                                ),
                                trailing: const Icon(
                                  Icons.copy_rounded,
                                  size: 18,
                                ),
                                onTap: () async {
                                  final messenger = ScaffoldMessenger.of(
                                    context,
                                  );
                                  await Clipboard.setData(
                                    ClipboardData(text: '${ntfy['topic']}'),
                                  );
                                  messenger.showSnackBar(
                                    const SnackBar(
                                      content: Text('已複製 topic'),
                                      duration: Duration(seconds: 1),
                                    ),
                                  );
                                },
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  4,
                                  16,
                                  14,
                                ),
                                child: Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      icon: const Icon(
                                        Icons.open_in_new_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('在 ntfy App 訂閱'),
                                      onPressed: () {
                                        final server = Uri.parse(
                                          '${ntfy['server']}',
                                        );
                                        launchUrl(
                                          Uri.parse(
                                            'ntfy://${server.host}/${ntfy['topic']}',
                                          ),
                                          mode: LaunchMode.externalApplication,
                                        );
                                      },
                                    ),
                                    OutlinedButton.icon(
                                      icon: const Icon(
                                        Icons.send_rounded,
                                        size: 18,
                                      ),
                                      label: const Text('傳送測試'),
                                      onPressed: () async {
                                        final messenger = ScaffoldMessenger.of(
                                          context,
                                        );
                                        final r = await client.request(
                                          '_codeaw/notify/test',
                                        ) as Map<String, dynamic>;
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
                          ),
                      ]),
                    ],
                    if (state.androidLiveActivity.channel.platformSupported)
                      ListenableBuilder(
                        listenable: state.androidLiveActivity,
                        // A phone that cannot show it has nothing to switch on.
                        builder: (context, _) =>
                            state.androidLiveActivity.support.available
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const _Section('背景進度'),
                                  _Group([_LiveActivityTiles(state: state)]),
                                ],
                              )
                            : const SizedBox.shrink(),
                      ),
                    const _Section('其他'),
                    _Group([
                      ListTile(
                        leading: const Icon(Icons.history_rounded),
                        title: const Text('清除本機聊天快取'),
                        subtitle: const Text('電腦上的對話不受影響'),
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
                    ]),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
    );
  }
}

class _LiveActivityTiles extends StatelessWidget {
  const _LiveActivityTiles({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final tracker = state.androidLiveActivity;
    return ListenableBuilder(
      listenable: tracker,
      builder: (context, _) {
        final support = tracker.support;
        final on = tracker.enabled && support.available;
        final scheme = Theme.of(context).colorScheme;
        Widget warning(String title, String subtitle) => ListTile(
          leading: Icon(Icons.warning_amber_rounded, color: scheme.error),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: () => tracker.channel.openSettings(),
        );
        return Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.timelapse_rounded),
              title: const Text('背景即時進度'),
              subtitle: const Text('切到背景時用常駐通知顯示進度，並保持連線'),
              value: on,
              onChanged: support.available
                  ? (value) async {
                      if (value) await state.notifier.requestPermission();
                      await tracker.setEnabled(value);
                      await tracker.refreshSupport();
                    }
                  : null,
            ),
            if (on && !support.allowed) warning('通知已關閉', '開啟 App 通知才能顯示背景進度'),
            if (on && support.allowed && support.promoted == false)
              warning('即時更新已關閉', '目前以一般通知顯示，可到系統設定開啟'),
          ],
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 22, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

/// One section's settings on a shared card, separated by hairlines.
class _Group extends StatelessWidget {
  const _Group(this.children);
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CodeawRadii.lg),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .6)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, child) in children.indexed) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    indent: 56,
                    endIndent: 16,
                    color: scheme.outlineVariant.withValues(alpha: .6),
                  ),
                child,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
