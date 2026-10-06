import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../../data/models.dart';
import '../../main.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';
import 'host_sheet.dart';
import 'new_session_sheet.dart';
import 'delete_chat.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    this.sidebar = false,
    this.selectedSessionId,
    this.onSessionSelected,
  });
  final bool sidebar;
  final String? selectedSessionId;
  final VoidCallback? onSessionSelected;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  String? _agentFilter;
  String _query = '';
  BridgeClient? _client;
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final client = state.client;
    final model = state.sessions;
    if (!identical(_client, client)) {
      _client = client;
      _agentFilter = null;
      _query = '';
      _search.clear();
    }
    if (client == null || model == null) {
      return const Scaffold(body: SizedBox.shrink());
    }
    return ListenableBuilder(
      listenable: Listenable.merge([client, model]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final all = model.sessions.where(
          (s) => !client.isOnline || client.agent(s.agentId) != null,
        );
        final visible = all
            .where(
              (s) =>
                  (_agentFilter == null || s.agentId == _agentFilter) &&
                  (_query.isEmpty ||
                      '${s.displayTitle} ${s.displayLocation} ${s.cwd} ${client.agent(s.agentId)?.name}'
                          .toLowerCase()
                          .contains(_query)),
            )
            .toList();
        final attention = visible
            .where((s) => s.pending > 0 || s.state != 'idle')
            .toList();
        final rest = visible
            .where((s) => !(s.pending > 0 || s.state != 'idle'))
            .toList();
        final body = Column(
          children: [
            if (widget.sidebar) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
                child: Row(
                  children: [
                    Icon(Icons.code_rounded, color: scheme.primary),
                    const SizedBox(width: 10),
                    Text(
                      'codeaw',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: '重新整理對話',
                      icon: const Icon(Icons.refresh_rounded),
                      onPressed: model.refresh,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  tileColor: scheme.surfaceContainerHighest.withValues(
                    alpha: .5,
                  ),
                  leading: Icon(Icons.computer_rounded, color: scheme.primary),
                  title: Text(
                    client.bridgeHost ?? state.host?.name ?? '電腦',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    client.isOnline ? '已連線' : '離線',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                  trailing: const Icon(Icons.unfold_more_rounded, size: 18),
                  onTap: () => showHostSheet(context),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: client.isOnline
                        ? () {
                            widget.onSessionSelected?.call();
                            showNewSessionSheet(context);
                          }
                        : null,
                    icon: const Icon(Icons.add_rounded, size: 20),
                    label: const Text('新對話'),
                  ),
                ),
              ),
            ],
            const ConnectionBanner(),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: TextField(
                controller: _search,
                onChanged: (value) =>
                    setState(() => _query = value.trim().toLowerCase()),
                decoration: InputDecoration(
                  hintText: '搜尋對話或資料夾',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清除搜尋',
                          icon: const Icon(Icons.close_rounded, size: 18),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  isDense: true,
                  fillColor: scheme.surfaceContainerHighest.withValues(
                    alpha: .45,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            if (client.agents.isNotEmpty)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ChoiceChip(
                        label: const Text('全部'),
                        selected: _agentFilter == null,
                        onSelected: (_) => setState(() => _agentFilter = null),
                      ),
                    ),
                    for (final a in client.agents)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          avatar: AgentAvatar(
                            agentId: a.id,
                            label: a.name,
                            size: 20,
                          ),
                          showCheckmark: false,
                          label: Text(
                            a.name,
                            style: a.status == 'error'
                                ? TextStyle(color: scheme.error)
                                : null,
                          ),
                          selected: _agentFilter == a.id,
                          onSelected: (_) => setState(
                            () => _agentFilter = _agentFilter == a.id
                                ? null
                                : a.id,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            for (final e in model.agentErrors)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Text(
                  e,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: scheme.error, fontSize: 12),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  client.reconnectNow();
                  await model.refresh();
                },
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(bottom: widget.sidebar ? 16 : 96),
                  children: [
                    if (visible.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 64,
                        ),
                        child: Center(
                          child: model.loading
                              ? const CircularProgressIndicator()
                              : Text(
                                  _query.isNotEmpty
                                      ? '找不到符合的對話'
                                      : client.isOnline
                                      ? '還沒有對話，建立新對話開始吧'
                                      : '連上 bridge 後會顯示對話',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: scheme.outline),
                                ),
                        ),
                      ),
                    if (attention.isNotEmpty) const _Header('進行中'),
                    for (final s in attention) _tile(s),
                    if (rest.isNotEmpty) const _Header('最近對話'),
                    for (final s in rest) _tile(s),
                    if (model.hasMore)
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Center(
                          child: TextButton(
                            onPressed: model.loadMore,
                            child: const Text('載入更多'),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (widget.sidebar) ...[
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: () => _navigate('/terminal'),
                        icon: const Icon(Icons.terminal_rounded, size: 18),
                        label: const Text('終端機'),
                      ),
                    ),
                    IconButton(
                      tooltip: '用量與額度',
                      icon: const Icon(Icons.donut_large_rounded),
                      onPressed: () => _navigate('/usage'),
                    ),
                    IconButton(
                      tooltip: '設定',
                      icon: const Icon(Icons.settings_outlined),
                      onPressed: () => _navigate('/settings'),
                    ),
                  ],
                ),
              ),
            ],
          ],
        );
        if (widget.sidebar) {
          return Material(
            color: scheme.surfaceContainerLow,
            child: SafeArea(child: body),
          );
        }
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.computer_rounded),
              tooltip: '切換電腦',
              onPressed: () => showHostSheet(context),
            ),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('codeaw'),
                Text(
                  '${client.bridgeHost ?? state.host?.name ?? ''} · ${client.status == ConnStatus.online
                      ? '已連線'
                      : client.status == ConnStatus.connecting
                      ? '連線中'
                      : '離線'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.donut_large_rounded),
                tooltip: '用量與額度',
                onPressed: () => context.push('/usage'),
              ),
              IconButton(
                icon: const Icon(Icons.terminal_rounded),
                tooltip: '終端機',
                onPressed: () => context.push('/terminal'),
              ),
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: '設定',
                onPressed: () => context.push('/settings'),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: client.isOnline
                ? () => showNewSessionSheet(context)
                : null,
            icon: const Icon(Icons.add_rounded),
            label: const Text('新對話'),
          ),
          body: ContentFrame(child: body),
        );
      },
    );
  }

  void _navigate(String route) {
    final router = GoRouter.of(context);
    widget.onSessionSelected?.call();
    router.go(route);
  }

  Widget _tile(SessionSummary s) => _SessionTile(
    s,
    compact: widget.sidebar,
    selected: s.id == widget.selectedSessionId,
    onDelete: _client?.isOnline == true && s.state == 'idle' && s.pending == 0 && s.queued == 0 && AppScope.read(context).sessions?.isDeleting(s.id) != true
        ? () async {
            final deleted = await confirmDeleteChat(context, sessionId: s.id, title: s.displayTitle, desktopSync: s.desktopSync);
            if (deleted && mounted && widget.selectedSessionId == s.id) GoRouter.of(context).go('/');
          }
        : null,
    onTap: () {
      final router = GoRouter.of(context);
      final wide = MediaQuery.sizeOf(context).width >= tabletBreakpoint;
      widget.onSessionSelected?.call();
      final route =
          '${sessionRoute(s.id)}&cwd=${Uri.encodeQueryComponent(s.cwd)}';
      if (wide) {
        router.go(route);
      } else {
        router.push(route);
      }
    },
  );
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
    child: Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.outline,
      ),
    ),
  );
}

class _SessionTile extends StatelessWidget {
  const _SessionTile(
    this.s, {
    required this.compact,
    required this.selected,
    required this.onTap,
    this.onDelete,
  });
  final SessionSummary s;
  final bool compact;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final agent = AppScope.of(context).client?.agent(s.agentId);
    final badge = StateBadge(
      state: s.state,
      pending: s.pending,
      queued: s.queued,
    );
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 4, vertical: 2),
      child: ListTile(
        selected: selected,
        selectedTileColor: scheme.primary.withValues(alpha: .09),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12),
        leading: AgentAvatar(
          agentId: s.agentId,
          label: agent?.name,
          size: compact ? 28 : 32,
        ),
        title: Text(
          s.displayTitle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: compact ? 13 : 15,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${s.displayLocation} · ${timeAgo(s.updatedAt)}${s.known ? '' : ' · 電腦上的對話'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: scheme.outline,
                fontSize: compact ? 11 : 12.5,
              ),
            ),
            if (compact && (s.pending > 0 || s.state != 'idle'))
              Padding(padding: const EdgeInsets.only(top: 4), child: badge),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!compact) badge,
            IconButton(tooltip: '刪除聊天', icon: const Icon(Icons.delete_outline_rounded), onPressed: onDelete),
          ],
        ),
        onTap: onTap,
      ),
    );
  }
}
