import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../common/widgets.dart';
import 'new_session_sheet.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key});

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  String? _agentFilter;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final model = state.sessions;
    if (client == null || model == null) return const Scaffold(body: SizedBox.shrink());
    return ListenableBuilder(
      listenable: Listenable.merge([client, model]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final all = model.sessions.where((s) => client.agent(s.agentId) != null).toList();
        final visible = _agentFilter == null ? all : all.where((s) => s.agentId == _agentFilter).toList();
        final attention = visible.where((s) => s.pending > 0 || s.state != 'idle').toList();
        final rest = visible.where((s) => !(s.pending > 0 || s.state != 'idle')).toList();
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('codeaw'),
              Text(
                '${client.bridgeHost ?? state.host?.name ?? ''} · ${client.status == ConnStatus.online ? '已連線' : client.status == ConnStatus.connecting ? '連線中' : '離線'}',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ]),
            actions: [
              IconButton(icon: const Icon(Icons.terminal_rounded), tooltip: '終端機', onPressed: () => context.push('/terminal')),
              IconButton(icon: const Icon(Icons.settings_outlined), tooltip: '設定', onPressed: () => context.push('/settings')),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: client.isOnline ? () => showNewSessionSheet(context) : null,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新對話'),
          ),
          body: Column(
            children: [
              const ConnectionBanner(),
              if (client.agents.isNotEmpty)
                SizedBox(
                  height: 48,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(label: const Text('全部'), selected: _agentFilter == null, onSelected: (_) => setState(() => _agentFilter = null)),
                      ),
                      for (final a in client.agents)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            avatar: Icon(Icons.circle, size: 10, color: a.status == 'error' ? scheme.error : agentColor(a.id)),
                            label: Text(a.name),
                            selected: _agentFilter == a.id,
                            onSelected: (_) => setState(() => _agentFilter = _agentFilter == a.id ? null : a.id),
                          ),
                        ),
                    ],
                  ),
                ),
              for (final e in model.agentErrors)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                  child: Text(e, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: scheme.error, fontSize: 12)),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    client.reconnectNow();
                    await model.refresh();
                  },
                  child: visible.isEmpty
                      ? ListView(children: [
                          const SizedBox(height: 120),
                          Center(
                            child: model.loading
                                ? const CircularProgressIndicator()
                                : Text(client.isOnline ? '還沒有對話，按「新對話」開始' : '連上 bridge 後會顯示對話', style: TextStyle(color: scheme.outline)),
                          ),
                        ])
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 96),
                          children: [
                            if (attention.isNotEmpty) _Header('進行中'),
                            for (final s in attention) _SessionTile(s),
                            if (attention.isNotEmpty && rest.isNotEmpty) _Header('最近'),
                            for (final s in rest) _SessionTile(s),
                            if (model.hasMore)
                              Padding(
                                padding: const EdgeInsets.all(12),
                                child: Center(child: TextButton(onPressed: model.loadMore, child: const Text('載入更多'))),
                              ),
                          ],
                        ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: Theme.of(context).colorScheme.primary)),
      );
}

class _SessionTile extends StatelessWidget {
  const _SessionTile(this.s);
  final SessionSummary s;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agent = AppScope.of(context).client?.agent(s.agentId);
    return ListTile(
      leading: AgentAvatar(agentId: s.agentId, label: agent?.name),
      title: Text(s.displayTitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Row(children: [
        Flexible(
          child: Text(
            '${folderName(s.cwd)} · ${timeAgo(s.updatedAt)}${s.known ? '' : ' · 電腦上的對話'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: scheme.outline, fontSize: 12.5),
          ),
        ),
      ]),
      trailing: StateBadge(state: s.state, pending: s.pending, queued: s.queued),
      onTap: () => context.push('${sessionRoute(s.id)}&cwd=${Uri.encodeQueryComponent(s.cwd)}'),
    );
  }
}
