import 'package:flutter/material.dart';

import '../../data/subagent.dart';
import '../../data/timeline.dart';
import 'subagent_status.dart';

/// Delegation stays in the conversation, with its transcript folded underneath.
class SubagentCard extends StatefulWidget {
  const SubagentCard({
    super.key,
    required this.tool,
    required this.timeline,
    required this.itemBuilder,
    required this.report,
    this.nested = false,
    this.initiallyExpanded = false,
  });

  final ToolItem tool;
  final Timeline timeline;
  final Widget Function(TimelineItem) itemBuilder;
  final Widget report;
  final bool nested;
  final bool initiallyExpanded;

  @override
  State<SubagentCard> createState() => _SubagentCardState();
}

class _SubagentCardState extends State<SubagentCard> {
  bool _open = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _open = PageStorage.maybeOf(context)?.readState(context, identifier: widget.tool.key) as bool? ?? widget.initiallyExpanded;
  }

  void _toggle() {
    setState(() => _open = !_open);
    PageStorage.maybeOf(context)?.writeState(context, _open, identifier: widget.tool.key);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tool = widget.tool;
    final info = tool.subagent;
    final children = widget.timeline.childrenOf(tool);
    final label = subagentStatusLabel(widget.timeline, tool);
    final tools = children.whereType<ToolItem>().toList();
    final completed = tools.where((t) => t.status == 'completed').length;
    final latest = widget.timeline.currentActivityOf(tool);
    final latestText = switch (latest) {
      ToolItem t => t.displayTitle,
      MessageItem m => m.text,
      _ => null,
    };
    final result = widget.timeline.resultOfSubagent(tool);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: widget.nested ? 0 : 12, vertical: 5),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: scheme.primary.withValues(alpha: 0.25)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              button: true,
              expanded: _open,
              label: '子代理 ${info?.name ?? tool.title ?? ''}，$label',
              child: InkWell(
                onTap: _toggle,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(Icons.account_tree_outlined, size: 20, color: scheme.primary),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '子代理${info?.role == null ? '' : ' · ${info!.role}'}',
                              style: TextStyle(fontSize: 11, color: scheme.primary, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              info?.name ?? tool.title ?? '子代理',
                              maxLines: _open ? 4 : 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 7),
                            Wrap(
                              spacing: 8,
                              runSpacing: 5,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SubagentStatusBadge(timeline: widget.timeline, tool: tool),
                                if (tools.isNotEmpty)
                                  Text('工具 $completed/${tools.length}', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                                if (info?.model case final String model)
                                  Text(model, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
                              ],
                            ),
                            if (!_open && nonEmptyString(latestText) != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 7),
                                child: Text(
                                  latestText!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                                ),
                              ),
                          ],
                        ),
                      ),
                      Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: scheme.outline),
                    ],
                  ),
                ),
              ),
            ),
            if (_open) ...[
              Divider(height: 1, color: scheme.outlineVariant.withValues(alpha: 0.6)),
              if (info?.task case final String task)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '任務',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary),
                      ),
                      const SizedBox(height: 5),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 180),
                        child: SingleChildScrollView(child: SelectableText(task, style: const TextStyle(fontSize: 13))),
                      ),
                    ],
                  ),
                ),
              if (children.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Text(
                    '活動紀錄 · ${children.length}',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: scheme.primary),
                  ),
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 440),
                  child: ListView.builder(
                    key: PageStorageKey('subagent-activity:${tool.toolCallId}'),
                    shrinkWrap: true,
                    primary: false,
                    padding: const EdgeInsets.only(bottom: 8),
                    itemCount: children.length,
                    itemBuilder: (context, index) => widget.itemBuilder(children[index]),
                  ),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                  child: Text('尚無子代理活動紀錄', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                ),
              if (result != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: SingleChildScrollView(child: SelectableText(result, style: const TextStyle(fontSize: 13))),
                  ),
                ),
              widget.report,
            ],
          ],
        ),
      ),
    );
  }
}
