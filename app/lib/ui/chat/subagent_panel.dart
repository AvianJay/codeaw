import 'package:flutter/material.dart';

import '../../data/session_controller.dart';
import '../../data/timeline.dart';
import 'items.dart';
import 'subagent_status.dart';

/// The same agent browser is used by the phone drawer and desktop sidebar.
class SubagentPanel extends StatefulWidget {
  const SubagentPanel({super.key, required this.controller, this.onClose});
  final SessionController controller;
  final VoidCallback? onClose;

  @override
  State<SubagentPanel> createState() => _SubagentPanelState();
}

class _SubagentPanelState extends State<SubagentPanel> {
  String? _selectedId;
  bool _onlyActive = false;
  final _detailsStorage = PageStorageBucket();

  @override
  void didUpdateWidget(SubagentPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _selectedId = null;
      _onlyActive = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final timeline = widget.controller.timeline;
    return ListenableBuilder(
      listenable: timeline,
      builder: (context, _) {
        final agents = timeline.subagents;
        return ListenableBuilder(
          listenable: Listenable.merge(agents),
          builder: (context, _) {
            final scheme = Theme.of(context).colorScheme;
            final selected = agents.where((a) => a.toolCallId == _selectedId).firstOrNull;
            final active = agents.where((a) => subagentIsUnfinished(timeline.statusOfSubagent(a))).length;
            final filtered = agents.where((a) => !_onlyActive || subagentIsUnfinished(timeline.statusOfSubagent(a))).toList();
            // Active work comes first; retain chronological order within each group.
            final visible = [
              ...filtered.where((a) => subagentIsUnfinished(timeline.statusOfSubagent(a))),
              ...filtered.where((a) => !subagentIsUnfinished(timeline.statusOfSubagent(a))),
            ];
            return ColoredBox(
              color: scheme.surfaceContainerLow,
              child: SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                      child: Row(
                        children: [
                          Icon(Icons.account_tree_outlined, size: 20, color: scheme.primary),
                          const SizedBox(width: 8),
                          Expanded(child: Text('所有子代理', style: Theme.of(context).textTheme.titleMedium)),
                          if (widget.onClose != null)
                            IconButton(tooltip: '關閉子代理面板', onPressed: widget.onClose, icon: const Icon(Icons.close_rounded)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: Text('共 ${agents.length} 個 · $active 個未結束', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                    ),
                    if (selected != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () => setState(() => _selectedId = null),
                          icon: const Icon(Icons.arrow_back_rounded, size: 18),
                          label: const Text('返回所有子代理'),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            ChoiceChip(
                              label: const Text('全部'),
                              selected: !_onlyActive,
                              onSelected: (_) => setState(() => _onlyActive = false),
                            ),
                            ChoiceChip(
                              label: const Text('未結束'),
                              selected: _onlyActive,
                              onSelected: (_) => setState(() => _onlyActive = true),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 8),
                    Divider(height: 1, color: scheme.outlineVariant),
                    Expanded(
                      child: selected != null
                          ? PageStorage(
                              bucket: _detailsStorage,
                              child: ListView(
                                children: [
                                  TimelineItemView(
                                    key: ValueKey('detail:${selected.key}'),
                                    item: selected,
                                    controller: widget.controller,
                                    isLast: false,
                                    expandSubagent: true,
                                  ),
                                ],
                              ),
                            )
                          : visible.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(
                                  agents.isEmpty ? '這個對話還沒有子代理' : '沒有未結束的子代理',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: scheme.onSurfaceVariant),
                                ),
                              ),
                            )
                          : ListView.builder(
                              key: const PageStorageKey('subagent-list'),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              itemCount: visible.length,
                              itemBuilder: (context, index) => _AgentRow(
                                tool: visible[index],
                                timeline: timeline,
                                onTap: () => setState(() => _selectedId = visible[index].toolCallId),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _AgentRow extends StatelessWidget {
  const _AgentRow({required this.tool, required this.timeline, required this.onTap});
  final ToolItem tool;
  final Timeline timeline;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final info = tool.subagent;
    final parent = timeline.parentOf(tool);
    final tools = timeline.descendantsOf(tool).whereType<ToolItem>().toList();
    final done = tools.where((t) => t.status == 'completed').length;
    final latest = timeline.currentActivityOf(tool);
    final activity = switch (latest) {
      ToolItem t => t.title,
      MessageItem m => m.text,
      _ => info?.task,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('subagent-row:${tool.toolCallId}'),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (parent != null)
                  Row(
                    children: [
                      Icon(Icons.subdirectory_arrow_right_rounded, size: 13, color: scheme.outline),
                      const SizedBox(width: 3),
                      Expanded(
                        child: Text(
                          parent.subagent?.name ?? parent.title ?? '子代理',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: scheme.outline),
                        ),
                      ),
                    ],
                  ),
                Text(
                  info?.name ?? tool.title ?? '子代理',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 7),
                Wrap(
                  spacing: 8,
                  runSpacing: 5,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SubagentStatusBadge(timeline: timeline, tool: tool),
                    if (info?.role != null) Text(info!.role!, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                    if (tools.isNotEmpty) Text('工具 $done/${tools.length}', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                  ],
                ),
                if (activity?.trim().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Text(
                      activity!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
