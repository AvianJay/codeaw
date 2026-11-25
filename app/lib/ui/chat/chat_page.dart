import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../data/session_controller.dart';
import '../../data/timeline.dart';
import '../../data/tool_display.dart';
import '../common/adaptive.dart';
import '../common/app_theme.dart';
import '../common/error_text.dart';
import '../common/widgets.dart';
import 'agent_cards.dart';
import 'composer.dart';
import 'chat_header.dart';
import 'elicitation_sheet.dart';
import 'items.dart';
import 'subagent_panel.dart';
import 'working_indicator.dart';
import 'scroll_to_latest.dart';
import '../sessions/delete_chat.dart';

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
  SessionHub? _hub;
  StreamSubscription<String>? _toasts;
  final _scaffold = GlobalKey<ScaffoldState>();
  bool? _showSubagents;
  double _horizontalTravel = 0;

  void _backToChats() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else {
      router.go('/');
    }
  }

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
    if (_c case final previous?) _hub?.release(previous.sessionId);
    _c = null;
    final hub = _hub = state.hub;
    if (hub == null || widget.sessionId.isEmpty) return;
    final summary = state.sessions?.byId(widget.sessionId);
    final cwd = widget.cwd ?? summary?.cwd;
    _c = hub.open(widget.sessionId, cwd: cwd, projectless: summary?.projectless);
    _toasts = _c!.toasts.listen((msg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorText(msg))));
      }
    });
    state.client?.setForeground(true, activeSessionId: widget.sessionId);
    state.liveActivity.follow(widget.sessionId);
  }

  @override
  void dispose() {
    _toasts?.cancel();
    // A chat replaced by an edited branch is forgotten once its page is gone.
    if (_c case final c?) _hub?.release(c.sessionId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    if (c == null) {
      return Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: useWideLayout(context) ? null : BackButton(onPressed: _backToChats),
          title: const Text('聊天'),
        ),
        body: const Center(child: Text('找不到這個對話')),
      );
    }
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([c, c.timeline, if (state.cpa != null) state.cpa!]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final quotaConfigured = state.cpa?.settings != null;
        final summary = state.sessions?.byId(c.sessionId);
        final title = c.timeline.title ?? summary?.title ?? c.displayLocation;
        final agentName = c.agent?.name ?? c.agentId;
        return LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;
            final compact = constraints.maxWidth < 600 || !useWideLayout(context);
            // Subagent controls appear once the conversation has delegated work.
            final subagentCount = c.timeline.subagents.length;
            final drawer = !wide && subagentCount > 0;
            final showSubagents = subagentCount > 0 && (_showSubagents ?? true);
            return Scaffold(
              key: _scaffold,
              endDrawerEnableOpenDragGesture: drawer,
              endDrawer: !drawer
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
                automaticallyImplyLeading: false,
                leading: useWideLayout(context) ? null : BackButton(onPressed: _backToChats),
                titleSpacing: useWideLayout(context) ? 20 : 0,
                title: ChatHeaderTitle(
                  title: title,
                  subtitle: '$agentName · ${c.displayLocation}${c.desktopSync ? (c.desktopConnected ? ' · 桌面同步' : ' · 桌面未連線') : ''}',
                  agentId: c.agentId,
                  agentName: agentName,
                  model: c.modelFamily,
                  usage: state.cpa,
                  onUsageTap: () => context.push('/usage'),
                ),
                actions: [
                  if (subagentCount > 0 && (!quotaConfigured || constraints.maxWidth >= 430))
                    IconButton(
                      tooltip: '所有子代理',
                      isSelected: wide && showSubagents,
                      icon: Badge(
                        label: Text('$subagentCount'),
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
                  if (!compact && !c.projectless)
                    IconButton(
                      tooltip: 'Git 變更',
                      icon: const Icon(Icons.difference_outlined),
                      onPressed: c.cwd.isEmpty ? null : () => context.push('/git?cwd=${Uri.encodeQueryComponent(c.cwd)}'),
                    ),
                  PopupMenuButton<String>(
                    tooltip: '更多',
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
                        case 'delete':
                          if (await confirmDeleteChat(context, sessionId: c.sessionId, title: title, desktopSync: c.desktopSync) && context.mounted) context.go('/');
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'usage', child: Text('CPA 用量')),
                      if (subagentCount > 0 && quotaConfigured && constraints.maxWidth < 430) const PopupMenuItem(value: 'subagents', child: Text('所有子代理')),
                      if (quotaConfigured && constraints.maxWidth < 360) PopupMenuItem(value: 'files', enabled: c.cwd.isNotEmpty, child: const Text('檔案')),
                      if (compact) PopupMenuItem(value: 'terminal', enabled: c.cwd.isNotEmpty, child: const Text('終端機')),
                      if (compact && !c.projectless) PopupMenuItem(value: 'git', enabled: c.cwd.isNotEmpty, child: const Text('Git 變更')),
                      const PopupMenuItem(value: 'reimport', child: Text('從電腦重新載入歷史')),
                      PopupMenuItem(value: 'close', child: Text(c.desktopSync ? '停止桌面同步' : '釋放 agent 資源')),
                      PopupMenuItem(value: 'copy', child: Text('複製 session id')),
                      PopupMenuItem(value: 'delete', enabled: c.client.isOnline && !c.loading && !c.running && c.pending.isEmpty && c.timeline.queued == 0, child: const Text('刪除聊天')),
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
                              if (c.waitingForDesktop && c.client.isOnline)
                                Material(
                                  color: scheme.secondaryContainer,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                                    child: Row(children: [
                                      const Icon(Icons.sync_rounded, size: 16),
                                      const SizedBox(width: 8),
                                      Expanded(child: Text('等待桌面恢復連線。一直連不上時，請在 Codex 桌面開啟這個聊天。', style: TextStyle(color: scheme.onSecondaryContainer, fontSize: 12))),
                                    ]),
                                  ),
                                ),
                              if (c.error != null)
                                MaterialBanner(
                                  content: Text(errorText(c.error!)),
                                  actions: [TextButton(onPressed: c.attach, child: const Text('重試'))],
                                ),
                              if (c.timeline.plan != null && c.timeline.plan!.isNotEmpty) _PlanPanel(c.timeline.plan!),
                            ],
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onHorizontalDragStart: !drawer ? null : (_) => _horizontalTravel = 0,
                            onHorizontalDragUpdate: !drawer ? null : (details) => _horizontalTravel += details.delta.dx,
                            onHorizontalDragEnd: !drawer
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
                          child: SuggestedReplies(controller: c),
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
    final items = chatTimelineItems(controller);
    final running = controller.running;
    final older = controller.hasOlder;
    if (items.isEmpty && !running && !older) {
      final scheme = Theme.of(context).colorScheme;
      return Center(
        child: controller.loading
            ? const CircularProgressIndicator()
            : Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.chat_bubble_outline_rounded, size: 36, color: scheme.outline.withValues(alpha: .6)),
                  const SizedBox(height: 12),
                  Text('開始對話吧', style: TextStyle(color: scheme.outline)),
                ],
              ),
      );
    }
    // The request bar under the list already says what the turn waits for; the
    // indicator stays only when it also has a queue or thoughts to show.
    final asked =
        controller.timeline.state == 'requires_action' &&
        controller.pending.isNotEmpty &&
        controller.timeline.queued == 0 &&
        !controller.thoughtSummary;
    final extra = running && !asked ? 1 : 0;
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
        itemCount: items.length + extra + (older ? 1 : 0),
        itemBuilder: (context, index) {
          if (extra == 1 && index == 0) {
            return WorkingIndicator(
              key: ValueKey('working:${controller.sessionId}'),
              timeline: controller.timeline,
              showThoughts: controller.thoughtSummary,
              waitingForInput: controller.pending.values.any((req) => !req.isPermission),
            );
          }
          if (index == items.length + extra) {
            return _OlderHistory(key: ValueKey('older:${controller.sessionId}'), controller: controller);
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

/// The top of a paged history. The list builds it only near the viewport, so
/// building it fetches the previous page; a failed page waits for a tap.
class _OlderHistory extends StatelessWidget {
  const _OlderHistory({super.key, required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final ready = c.client.isOnline && c.attached;
    if (ready && !c.loadingOlder && c.olderError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => c.loadOlder());
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: c.loadingOlder
            ? const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : TextButton.icon(
                onPressed: ready ? c.loadOlder : null,
                icon: const Icon(Icons.history_rounded, size: 18),
                label: Text(c.olderError ?? (ready ? '載入較早的訊息' : '連上電腦後可載入較早的訊息')),
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
    final total = widget.entries.length;
    final done = widget.entries.where((e) => e['status'] == 'completed').length;
    final current = widget.entries.firstWhere((e) => e['status'] == 'in_progress', orElse: () => const {});
    // In the page's column above the conversation, so it never covers a message;
    // kept as short as a single line so the conversation keeps its room.
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(CodeawRadii.md),
          side: BorderSide(color: scheme.outlineVariant.withValues(alpha: .7)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _open = !_open),
          child: Stack(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(12, 7, 8, _open ? 12 : 7),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.checklist_rounded, size: 18, color: scheme.primary),
                        const SizedBox(width: 8),
                        Text(
                          '計畫 $done/$total',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 13,
                            color: scheme.onSurface,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (!_open && current.isNotEmpty)
                          Expanded(
                            child: Text(
                              '${current['content']}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                            ),
                          )
                        else
                          const Spacer(),
                        const SizedBox(width: 4),
                        Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: scheme.outline),
                      ],
                    ),
                    if (_open)
                      for (final e in widget.entries)
                        Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Icon(
                                  switch (e['status']) {
                                    'completed' => Icons.check_circle_rounded,
                                    'in_progress' => Icons.radio_button_checked_rounded,
                                    _ => Icons.radio_button_unchecked_rounded,
                                  },
                                  size: 16,
                                  color: e['status'] == 'completed'
                                      ? scheme.success
                                      : e['status'] == 'in_progress'
                                      ? scheme.primary
                                      : scheme.outline,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '${e['content']}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    height: 1.4,
                                    fontWeight: e['status'] == 'in_progress' ? FontWeight.w600 : FontWeight.w400,
                                    decoration: e['status'] == 'completed' ? TextDecoration.lineThrough : null,
                                    decorationColor: scheme.outline,
                                    color: e['status'] == 'completed' ? scheme.outline : scheme.onSurface,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
              ),
              // Progress along the bottom edge; drawn, not a progress indicator, since it never animates.
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 2.5,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ColoredBox(color: scheme.surfaceContainerHighest),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: total == 0 ? 0 : done / total,
                      child: ColoredBox(color: done == total ? scheme.success : scheme.primary),
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
    final accent = req.isPermission ? scheme.warning : scheme.tertiary;
    final detail = req.isPermission ? _detail(req) : null;
    return Material(
      color: Color.alphaBlend(accent.withValues(alpha: .08), scheme.surfaceContainerLow),
      shape: Border(top: BorderSide(color: accent.withValues(alpha: .4))),
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      req.isPermission ? toolIcon(toolKind) : Icons.help_outline_rounded,
                      size: 18,
                      color: accent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      req.isPermission ? '需要批准：${toolTitle(title: req.title, name: req.toolCall['name'] as String?, rawInput: req.toolCall['rawInput'], metadata: req.toolCall['_meta'])}' : req.title,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, height: 1.35, color: scheme.onSurface),
                    ),
                  ),
                  if (controller.pending.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 8, top: 1),
                      child: Text('還有 ${controller.pending.length - 1} 個', style: TextStyle(fontSize: 12, color: scheme.outline)),
                    ),
                ],
              ),
              if (detail != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 8, left: 28),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest.withValues(alpha: .55),
                    borderRadius: BorderRadius.circular(CodeawRadii.sm),
                  ),
                  child: Text(
                    detail,
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.4, color: scheme.onSurfaceVariant),
                  ),
                ),
              const SizedBox(height: 12),
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
    final mcp = mcpToolOf(title: req.toolCall['title'] as String?, name: req.toolCall['name'] as String?, rawInput: input, metadata: req.toolCall['_meta']);
    if (mcp != null) return argumentSummary(mcp.arguments);
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
