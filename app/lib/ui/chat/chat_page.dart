import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../data/models.dart';
import '../../data/session_controller.dart';
import '../../data/timeline.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';
import 'composer.dart';
import 'chat_header.dart';
import 'elicitation_sheet.dart';
import 'items.dart';
import 'subagent_panel.dart';
import 'working_indicator.dart';
import 'scroll_to_latest.dart';

const _chatContentWidth = 960.0;

class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.sessionId, this.cwd});
  final String sessionId;
  final String? cwd;

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  SessionController? _c;
  StreamSubscription<String>? _toasts;
  final _scaffold = GlobalKey<ScaffoldState>();
  bool? _showSubagents;
  double _horizontalTravel = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindSession();
  }

  @override
  void didUpdateWidget(ChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sessionId != widget.sessionId) _bindSession();
  }

  void _bindSession() {
    final state = AppScope.read(context);
    if (_c?.sessionId == widget.sessionId && identical(_c?.client, state.client)) {
      return;
    }
    _toasts?.cancel();
    _showSubagents = null;
    _c = null;
    final hub = state.hub;
    if (hub == null || widget.sessionId.isEmpty) return;
    final cwd = widget.cwd ?? state.sessions?.byId(widget.sessionId)?.cwd;
    _c = hub.open(widget.sessionId, cwd: cwd);
    _toasts = _c!.toasts.listen((msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    });
    state.client?.setForeground(true, activeSessionId: widget.sessionId);
    state.liveActivity.follow(widget.sessionId);
  }

  @override
  void dispose() {
    _toasts?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) return const Scaffold(body: Center(child: Text('找不到這個對話')));
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.timeline, if (state.cpa != null) state.cpa!]),
      builder: (context, _) {
        final quotaConfigured = state.cpa?.settings != null;
        final summary = state.sessions?.byId(c.sessionId);
        final title = c.timeline.title ?? summary?.title ?? folderName(c.cwd);
        final agentName = c.agent?.name ?? c.agentId;
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;
            final compact = constraints.maxWidth < 600 || !useWideLayout(context);
            final showSubagents = _showSubagents ?? c.timeline.subagents.isNotEmpty;
            return Scaffold(
              key: _scaffold,
              endDrawerEnableOpenDragGesture: !wide,
              endDrawer: wide
                  ? null
                  : Drawer(
                      width: (constraints.maxWidth * .92).clamp(0.0, 380.0),
                      child: SubagentPanel(
                        key: ValueKey('drawer:${c.sessionId}'),
                        controller: c,
                        onClose: () => _scaffold.currentState?.closeEndDrawer(),
                      ),
                    ),
              appBar: AppBar(
                toolbarHeight: MediaQuery.sizeOf(context).height < 500 ? 44 : 56,
                automaticallyImplyLeading: !useWideLayout(context),
                titleSpacing: useWideLayout(context) ? 20 : 0,
                title: ChatHeaderTitle(
                  title: title,
                  subtitle: '$agentName · ${folderName(c.cwd)}${c.desktopSync ? (c.desktopConnected ? ' · 桌面同步' : ' · 桌面未連線') : ''}',
                  agentId: c.agentId,
                  agentName: agentName,
                  usage: state.cpa,
                  onUsageTap: () => context.push('/usage'),
                ),
                actions: [
                  if (!quotaConfigured || constraints.maxWidth >= 430)
                  IconButton(
                    tooltip: '所有子代理',
                    isSelected: wide && showSubagents,
                    icon: Badge(
                      isLabelVisible: c.timeline.subagents.isNotEmpty,
                      label: Text('${c.timeline.subagents.length}'),
                      child: const Icon(Icons.account_tree_outlined),
                    ),
                    onPressed: () {
                      if (wide) {
                        setState(() => _showSubagents = !showSubagents);
                      } else {
                        _scaffold.currentState?.openEndDrawer();
                      }
                    },
                  ),
                  if (c.desktopSync && !c.desktopConnected)
                    IconButton(tooltip: '重新連接桌面', icon: const Icon(Icons.sync_rounded), onPressed: c.loading ? null : () => c.attach()),
                  if (!compact)
                    IconButton(
                      tooltip: '終端機',
                      icon: const Icon(Icons.terminal_rounded),
                      onPressed: c.cwd.isEmpty ? null : () => context.push('/terminal?cwd=${Uri.encodeQueryComponent(c.cwd)}'),
                    ),
                  if (!quotaConfigured || constraints.maxWidth >= 360) IconButton(
                    tooltip: '檔案',
                    icon: const Icon(Icons.folder_outlined),
                    onPressed: c.cwd.isEmpty ? null : () => context.push('/files?path=${Uri.encodeQueryComponent(c.cwd)}'),
                  ),
                  if (!compact)
                    IconButton(
                      tooltip: 'Git 變更',
                      icon: const Icon(Icons.difference_outlined),
                      onPressed: c.cwd.isEmpty ? null : () => context.push('/git?cwd=${Uri.encodeQueryComponent(c.cwd)}'),
                    ),
                  PopupMenuButton<String>(
                    onSelected: (v) async {
                      switch (v) {
                        case 'usage':
                          context.push('/usage');
                        case 'subagents':
                          _scaffold.currentState?.openEndDrawer();
                        case 'files':
                          context.push('/files?path=${Uri.encodeQueryComponent(c.cwd)}');
                        case 'terminal':
                          context.push('/terminal?cwd=${Uri.encodeQueryComponent(c.cwd)}');
                        case 'git':
                          context.push('/git?cwd=${Uri.encodeQueryComponent(c.cwd)}');
                        case 'reimport':
                          await c.reimport();
                        case 'close':
                          if (await c.closeOnAgent() && context.mounted) {
                            ScaffoldMessenger.of(
                              context,
                            ).showSnackBar(SnackBar(content: Text(c.desktopSync ? '已停止桌面同步，桌面工作會繼續執行' : '已釋放電腦上的 agent 資源，再傳訊息會自動恢復')));
                          }
                        case 'copy':
                          await Clipboard.setData(ClipboardData(text: c.sessionId.substring(c.sessionId.indexOf(':') + 1)));
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'usage', child: Text('CPA 用量')),
                      if (quotaConfigured && constraints.maxWidth < 430) const PopupMenuItem(value: 'subagents', child: Text('所有子代理')),
                      if (quotaConfigured && constraints.maxWidth < 360) PopupMenuItem(value: 'files', enabled: c.cwd.isNotEmpty, child: const Text('檔案')),
                      if (compact) PopupMenuItem(value: 'terminal', enabled: c.cwd.isNotEmpty, child: const Text('終端機')),
                      if (compact) PopupMenuItem(value: 'git', enabled: c.cwd.isNotEmpty, child: const Text('Git 變更')),
                      const PopupMenuItem(value: 'reimport', child: Text('從電腦重新載入歷史')),
                      PopupMenuItem(value: 'close', child: Text(c.desktopSync ? '停止桌面同步' : '釋放 agent 資源')),
                      PopupMenuItem(value: 'copy', child: Text('複製 session id')),
                    ],
                  ),
                ],
              ),
              body: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        ContentWidth(
                          maxWidth: _chatContentWidth,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const ConnectionBanner(),
                              if (c.error != null)
                                MaterialBanner(
                                  content: Text(c.error!),
                                  actions: [TextButton(onPressed: c.attach, child: const Text('重試'))],
                                ),
                              if (c.timeline.plan != null && c.timeline.plan!.isNotEmpty) _PlanPanel(c.timeline.plan!),
                            ],
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onHorizontalDragStart: wide ? null : (_) => _horizontalTravel = 0,
                            onHorizontalDragUpdate: wide ? null : (details) => _horizontalTravel += details.delta.dx,
                            onHorizontalDragEnd: wide
                                ? null
                                : (details) {
                                    if (_horizontalTravel < -72 || (details.primaryVelocity ?? 0) < -450) {
                                      _scaffold.currentState?.openEndDrawer();
                                    }
                                  },
                            child: _TimelineList(controller: c),
                          ),
                        ),
                        if (c.pending.isNotEmpty)
                          ContentWidth(
                            maxWidth: _chatContentWidth,
                            child: _PendingBar(controller: c),
                          ),
                        ContentWidth(
                          maxWidth: _chatContentWidth,
                          child: Composer(controller: c),
                        ),
                      ],
                    ),
                  ),
                  if (wide && showSubagents) ...[
                    const VerticalDivider(width: 1),
                    SizedBox(
                      width: 350,
                      child: SubagentPanel(
                        key: ValueKey('sidebar:${c.sessionId}'),
                        controller: c,
                        onClose: () => setState(() => _showSubagents = false),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _TimelineList extends StatelessWidget {
  const _TimelineList({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final items = controller.timeline.rootItems;
    final running = controller.running;
    if (items.isEmpty && !running) {
      return Center(
        child: controller.loading
            ? const CircularProgressIndicator()
            : Text('開始對話吧', style: TextStyle(color: Theme.of(context).colorScheme.outline)),
      );
    }
    final extra = running ? 1 : 0;
    // Newest at the bottom: a reversed list keeps the view pinned to the end while streaming.
    return ScrollToLatest(
      key: ValueKey(controller.sessionId),
      builder: (context, scrollController) => ContentScrollFrame(
        maxWidth: _chatContentWidth,
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        builder: (context, padding) => ListView.builder(
        controller: scrollController,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        reverse: true,
        padding: padding,
        itemCount: items.length + extra,
        itemBuilder: (context, index) {
          if (running && index == 0) {
            return WorkingIndicator(
              key: ValueKey('working:${controller.sessionId}'),
              timeline: controller.timeline,
              waitingForInput: controller.pending.values.any((req) => !req.isPermission),
            );
          }
          final i = items.length - 1 - (index - extra);
          final item = items[i];
          return TimelineItemView(
            key: ValueKey(item.key),
            item: item,
            controller: controller,
            isLast: i == items.length - 1 || (i == items.length - 2 && items.last is! MessageItem),
          );
        },
        ),
      ),
    );
  }
}

class _PlanPanel extends StatefulWidget {
  const _PlanPanel(this.entries);
  final List<Map<String, dynamic>> entries;

  @override
  State<_PlanPanel> createState() => _PlanPanelState();
}

class _PlanPanelState extends State<_PlanPanel> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final done = widget.entries.where((e) => e['status'] == 'completed').length;
    final current = widget.entries.firstWhere((e) => e['status'] == 'in_progress', orElse: () => const {});
    return Material(
      color: scheme.surfaceContainerLow,
      child: InkWell(
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.checklist_rounded, size: 18, color: scheme.primary),
                  const SizedBox(width: 8),
                  Text('計畫 $done/${widget.entries.length}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  const SizedBox(width: 8),
                  if (!_open && current.isNotEmpty)
                    Expanded(
                      child: Text(
                        '${current['content']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: scheme.outline),
                      ),
                    )
                  else
                    const Spacer(),
                  Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18),
                ],
              ),
              if (_open)
                for (final e in widget.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 2),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          switch (e['status']) {
                            'completed' => Icons.check_circle_rounded,
                            'in_progress' => Icons.radio_button_checked_rounded,
                            _ => Icons.radio_button_unchecked_rounded,
                          },
                          size: 16,
                          color: e['status'] == 'completed'
                              ? Colors.green.shade600
                              : e['status'] == 'in_progress'
                              ? scheme.primary
                              : scheme.outline,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '${e['content']}',
                            style: TextStyle(
                              fontSize: 13,
                              decoration: e['status'] == 'completed' ? TextDecoration.lineThrough : null,
                              color: e['status'] == 'completed' ? scheme.outline : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Sticky bar above the composer for the oldest open request.
class _PendingBar extends StatelessWidget {
  const _PendingBar({required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final req = controller.pending.values.first;
    final scheme = Theme.of(context).colorScheme;
    final toolKind = req.toolCall['kind'] as String?;
    return Material(
      color: req.isPermission ? Colors.orange.withValues(alpha: 0.12) : scheme.tertiaryContainer.withValues(alpha: 0.5),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    req.isPermission ? toolIcon(toolKind) : Icons.help_outline_rounded,
                    size: 18,
                    color: req.isPermission ? Colors.orange.shade800 : scheme.tertiary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      req.isPermission ? '需要批准：${req.title}' : req.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                    ),
                  ),
                  if (controller.pending.length > 1)
                    Text('還有 ${controller.pending.length - 1} 個', style: TextStyle(fontSize: 12, color: scheme.outline)),
                ],
              ),
              if (req.isPermission && _detail(req) != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4, left: 26),
                  child: Text(
                    _detail(req)!,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 8),
              if (req.isPermission)
                PermissionButtons(req: req, controller: controller)
              else
                FilledButton.icon(
                  icon: const Icon(Icons.edit_note_rounded),
                  label: const Text('回答'),
                  onPressed: () => showElicitationSheet(context, controller, req),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String? _detail(PendingRequest req) {
    final input = req.toolCall['rawInput'];
    if (input is Map) {
      if (input['command'] != null) {
        return '\$ ${input['command'] is List ? (input['command'] as List).join(' ') : input['command']}';
      }
      if (input['file_path'] != null) return '${input['file_path']}';
      if (input['path'] != null) return '${input['path']}';
    }
    final tool = controller.timeline.items.whereType<ToolItem>().where((t) => t.toolCallId == req.toolCall['toolCallId']).firstOrNull;
    final ti = tool?.rawInput;
    if (ti is Map && ti['command'] != null) return '\$ ${ti['command']}';
    return null;
  }
}
