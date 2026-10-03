import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../../data/models.dart';
import '../../data/session_controller.dart';
import '../../data/timeline.dart';
import '../../util/diff.dart';
import '../common/code_view.dart';
import '../common/diff_view.dart';
import '../common/markdown.dart';
import 'elicitation_sheet.dart';
import 'subagent_card.dart';
import 'turn_summary.dart';

/// Builds the widget for one timeline item; rebuilt only when that item changes.
class TimelineItemView extends StatelessWidget {
  const TimelineItemView({super.key, required this.item, required this.controller, required this.isLast, this.depth = 0});

  final TimelineItem item;
  final SessionController controller;
  final bool isLast;
  final int depth;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: item,
      builder: (context, _) => switch (item) {
        MessageItem m => m.role == MessageRole.user
            ? UserMessageView(m)
            : m.role == MessageRole.thought
                ? ThoughtView(m)
                : AgentMessageView(m, streaming: isLast && controller.running, client: controller.client, basePath: controller.cwd),
        ToolItem t => controller.timeline.isSubagent(t)
            ? SubagentCard(
                tool: t,
                timeline: controller.timeline,
                nested: depth > 0,
                report: _ToolDetails(t, showInput: false, showEmpty: false, excludeText: t.subagent?.task),
                itemBuilder: (child) => TimelineItemView(key: ValueKey(child.key), item: child, controller: controller, isLast: false, depth: depth + 1),
              )
            : ToolCallCard(t, controller: controller),
        PermissionItem p => PermissionCard(p, controller: controller),
        ElicitationItem e => ElicitationCard(e, controller: controller),
        NoticeItem n => _Note(icon: Icons.info_outline_rounded, text: n.description == null ? n.title : '${n.title}\n${n.description}'),
        ErrorItem e => _Note(icon: Icons.error_outline_rounded, text: e.message, error: true),
        StopItem s => _Note(icon: Icons.stop_circle_outlined, text: stopReasonLabel(s.stopReason)),
        TurnSummaryItem t => TurnSummaryView(
            turn: t,
            onReusePrompt: controller.running || t.prompt?.text.isNotEmpty != true ? null : () => controller.reusePrompt(t.prompt!),
          ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

String stopReasonLabel(String reason) => switch (reason) {
      'cancelled' => '已停止',
      'max_tokens' => '達到輸出長度上限',
      'max_turn_requests' => '達到單回合請求上限',
      'refusal' => 'Agent 拒絕繼續',
      'error' => '回合因錯誤結束',
      _ => '回合結束：$reason',
    };

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text, this.error = false});
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = error ? scheme.error : scheme.outline;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: SelectableText(text, style: TextStyle(fontSize: 12.5, color: color))),
      ]),
    );
  }
}

class UserMessageView extends StatelessWidget {
  const UserMessageView(this.m, {super.key});
  final MessageItem m;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final badges = <String>[
      if (m.steered) '插入回合中',
      if (m.queued && m.dequeued == null) '排隊中',
      if (m.dequeued == 'cancelled') '已取消',
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(48, 10, 12, 4),
      child: Align(
        alignment: Alignment.centerRight,
        child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: m.dequeued == 'cancelled' ? scheme.surfaceContainerHighest : scheme.primaryContainer,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(4),
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final p in m.parts) _UserPart(p),
            ]),
          ),
          if (badges.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text(badges.join(' · '), style: TextStyle(fontSize: 11, color: scheme.outline)),
            ),
        ]),
      ),
    );
  }
}

class _UserPart extends StatelessWidget {
  const _UserPart(this.part);
  final Map<String, dynamic> part;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    switch (part['type']) {
      case 'text':
        return SelectableText(part['text'] as String? ?? '', style: TextStyle(color: scheme.onPrimaryContainer, height: 1.35));
      case 'image':
        return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: BlockImage(part, maxHeight: 220));
      default:
        final label = blockText(part);
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Chip(avatar: const Icon(Icons.attach_file_rounded, size: 16), label: Text(label.isEmpty ? '${part['type']}' : folderName(label), maxLines: 1)),
        );
    }
  }
}

/// An ACP image block: inline base64 or a `codeaw-blob:` reference served by the bridge.
class BlockImage extends StatelessWidget {
  const BlockImage(this.block, {super.key, this.maxHeight = 240});
  final Map<String, dynamic> block;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final data = block['data'] as String? ?? '';
    final uri = block['uri'] as String? ?? '';
    Widget img;
    if (data.isNotEmpty) {
      img = Image.memory(base64Decode(data), fit: BoxFit.contain);
    } else if (uri.startsWith('codeaw-blob:')) {
      final client = AppScope.of(context).client!;
      img = Image.network(
        client.httpUri('/api/blobs/${uri.substring(12)}').toString(),
        headers: client.authHeaders,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      );
    } else {
      img = const Icon(Icons.image_outlined);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(constraints: BoxConstraints(maxHeight: maxHeight), child: img),
    );
  }
}

class AgentMessageView extends StatelessWidget {
  const AgentMessageView(this.m, {super.key, required this.streaming, this.client, this.basePath});
  final MessageItem m;
  final bool streaming;
  final BridgeClient? client;
  final String? basePath;

  @override
  Widget build(BuildContext context) {
    final text = m.text;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: GestureDetector(
        onLongPress: () {
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已複製訊息'), duration: Duration(seconds: 1)));
        },
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (text.isNotEmpty) SelectionArea(child: Markdown(text, streaming: streaming, client: client, basePath: basePath)),
          for (final p in m.parts.where((p) => p['type'] == 'image')) Padding(padding: const EdgeInsets.only(top: 6), child: BlockImage(p)),
        ]),
      ),
    );
  }
}

class ThoughtView extends StatefulWidget {
  const ThoughtView(this.m, {super.key});
  final MessageItem m;

  @override
  State<ThoughtView> createState() => _ThoughtViewState();
}

class _ThoughtViewState extends State<ThoughtView> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = widget.m.text.trim();
    if (text.isEmpty) return const SizedBox.shrink();
    final firstLine = text.split('\n').first;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.psychology_alt_outlined, size: 16, color: scheme.outline),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                _open ? text : firstLine,
                maxLines: _open ? null : 1,
                overflow: _open ? null : TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic, color: scheme.outline, height: 1.35),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

IconData toolIcon(String? kind) => switch (kind) {
      'read' => Icons.description_outlined,
      'edit' => Icons.edit_note_rounded,
      'delete' => Icons.delete_outline_rounded,
      'move' => Icons.drive_file_move_outline,
      'search' => Icons.search_rounded,
      'execute' => Icons.terminal_rounded,
      'think' => Icons.account_tree_outlined,
      'fetch' => Icons.public_rounded,
      'switch_mode' => Icons.swap_horiz_rounded,
      _ => Icons.build_outlined,
    };

class ToolCallCard extends StatefulWidget {
  const ToolCallCard(this.t, {super.key, required this.controller});
  final ToolItem t;
  final SessionController controller;

  @override
  State<ToolCallCard> createState() => _ToolCallCardState();
}

class _ToolCallCardState extends State<ToolCallCard> {
  bool? _open;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    final scheme = Theme.of(context).colorScheme;
    final hasDiff = (t.content ?? const []).any((c) => c['type'] == 'diff');
    final open = _open ?? (hasDiff && t.kind == 'edit' && t.status != 'failed');
    final status = t.status ?? 'pending';
    final Widget statusIcon = switch (status) {
      'completed' => Icon(Icons.check_circle_rounded, size: 16, color: Colors.green.shade600),
      'failed' => Icon(Icons.cancel_rounded, size: 16, color: scheme.error),
      _ => const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
    };
    final exit = t.exitCode;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5))),
        clipBehavior: Clip.antiAlias,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: () => setState(() => _open = !open),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                Icon(toolIcon(t.kind), size: 18, color: scheme.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    (t.title?.isNotEmpty ?? false) ? t.title! : (t.name ?? '工具'),
                    maxLines: open ? 4 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500),
                  ),
                ),
                if (exit != null && exit != 0)
                  Padding(padding: const EdgeInsets.only(right: 6), child: Text('exit $exit', style: TextStyle(fontSize: 11, color: scheme.error))),
                statusIcon,
                Icon(open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: scheme.outline),
              ]),
            ),
          ),
          if (open) _ToolDetails(t),
        ]),
      ),
    );
  }
}

class _ToolDetails extends StatelessWidget {
  const _ToolDetails(this.t, {this.showInput = true, this.showEmpty = true, this.excludeText});
  final ToolItem t;
  final bool showInput;
  final bool showEmpty;
  final String? excludeText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final children = <Widget>[];
    final input = t.rawInput;
    if (showInput && input is Map && input['command'] != null) {
      final cmd = input['command'] is List ? (input['command'] as List).join(' ') : '${input['command']}';
      children.add(CodeBlock(code: '\$ $cmd', language: 'bash', wrap: true));
    }
    if (t.terminalOutput.isNotEmpty) {
      final out = t.terminalOutput.length > 20000 ? '…\n${t.terminalOutput.substring(t.terminalOutput.length - 20000)}' : t.terminalOutput;
      children.add(CodeBlock(code: out.trimRight(), maxHeight: 320, highlight: false));
    }
    for (final c in t.content ?? const <Map<String, dynamic>>[]) {
      switch (c['type']) {
        case 'diff':
          final path = '${c['path'] ?? ''}';
          children.add(Row(children: [
            Expanded(child: Text(path, style: TextStyle(fontSize: 12, color: scheme.outline), overflow: TextOverflow.ellipsis)),
            if (c['oldText'] == null) Text('新檔案', style: TextStyle(fontSize: 11, color: Colors.green.shade600)),
          ]));
          children.add(DiffView(lines: lineDiff(c['oldText'] as String?, c['newText'] as String? ?? ''), maxHeight: 360));
        case 'content':
          final block = c['content'] as Map<String, dynamic>? ?? const {};
          if (block['type'] == 'image') {
            children.add(BlockImage(block));
          } else {
            final text = blockText(block).trim();
            if (text.isEmpty || text == excludeText || (t.terminalOutput.isNotEmpty && text == t.terminalOutput.trim())) continue;
            children.add(_TextResult(text));
          }
        case 'terminal':
          if (t.terminalOutput.isEmpty && t.status == 'in_progress') {
            children.add(Text('執行中…', style: TextStyle(fontSize: 12, color: scheme.outline)));
          }
      }
    }
    final out = t.rawOutput;
    if (children.isEmpty || (t.content == null && t.terminalOutput.isEmpty)) {
      if (out is String && out.trim().isNotEmpty) {
        children.add(_TextResult(out.trim()));
      } else if (out is Map && out['formatted_output'] is String && t.terminalOutput.isEmpty) {
        children.add(CodeBlock(code: (out['formatted_output'] as String).trimRight(), maxHeight: 320, highlight: false));
      } else if (showInput && input != null && input is! String && !(input is Map && (input['command'] != null || input.isEmpty))) {
        children.add(CodeBlock(code: const JsonEncoder.withIndent('  ').convert(input), language: 'json', maxHeight: 240));
      }
    }
    final locations = t.locations ?? const <Map<String, dynamic>>[];
    if (locations.isNotEmpty) {
      children.add(Wrap(spacing: 6, runSpacing: 4, children: [
        for (final l in locations.take(8))
          ActionChip(
            visualDensity: VisualDensity.compact,
            avatar: const Icon(Icons.open_in_new_rounded, size: 14),
            label: Text('${folderName('${l['path']}')}${l['line'] != null ? ':${l['line']}' : ''}', style: const TextStyle(fontSize: 12)),
            onPressed: () => context.push('/file?path=${Uri.encodeQueryComponent('${l['path']}')}${l['line'] != null ? '&line=${l['line']}' : ''}'),
          ),
      ]));
    }
    if (children.isEmpty && !showEmpty) return const SizedBox.shrink();
    if (children.isEmpty) children.add(Text('（沒有輸出）', style: TextStyle(fontSize: 12, color: scheme.outline)));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final c in children) Padding(padding: const EdgeInsets.only(top: 6), child: c),
      ]),
    );
  }
}

class _TextResult extends StatelessWidget {
  const _TextResult(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final fence = RegExp(r'^```(\w*)\n([\s\S]*?)\n?```$').firstMatch(text);
    if (fence != null) return CodeBlock(code: fence.group(2)!, language: fence.group(1), maxHeight: 320, highlight: fence.group(1) != 'console');
    if (text.contains('\n') && text.length > 200) return CodeBlock(code: text, maxHeight: 320, highlight: false);
    return SelectableText(text, style: const TextStyle(fontSize: 13));
  }
}

class PermissionCard extends StatelessWidget {
  const PermissionCard(this.p, {super.key, required this.controller});
  final PermissionItem p;
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = controller.pending[p.requestId];
    final outcome = p.outcome?['outcome'];
    final (IconData icon, Color color, String label) = !p.resolved
        ? (Icons.pending_actions_rounded, Colors.orange, live != null ? '等待你的批准' : '等待批准')
        : outcome == 'cancelled'
            ? (Icons.block_rounded, scheme.outline, '已取消')
            : (p.optionName ?? '').toLowerCase().contains('reject') || (p.optionName ?? '').contains('拒') || (p.optionName ?? '').startsWith('No')
                ? (Icons.do_not_disturb_on_outlined, scheme.error, p.optionName ?? '已拒絕')
                : (Icons.verified_user_outlined, Colors.green.shade600, p.optionName ?? '已允許');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: !p.resolved ? Colors.orange.withValues(alpha: 0.08) : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: !p.resolved ? Colors.orange.withValues(alpha: 0.5) : scheme.outlineVariant.withValues(alpha: 0.5)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 8),
            Expanded(child: Text(p.title, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w500))),
          ]),
          const SizedBox(height: 4),
          Text('$label${p.by != null ? '（${p.by}）' : ''}', style: TextStyle(fontSize: 12, color: color)),
          if (live != null) ...[
            const SizedBox(height: 8),
            PermissionButtons(req: live, controller: controller),
          ],
        ]),
      ),
    );
  }
}

class PermissionButtons extends StatelessWidget {
  const PermissionButtons({super.key, required this.req, required this.controller});
  final PendingRequest req;
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(spacing: 8, runSpacing: 6, children: [
      for (final o in req.options)
        switch (o['kind']) {
          'allow_once' => FilledButton(onPressed: () => controller.answerPermission(req, '${o['optionId']}'), child: Text('${o['name']}')),
          'allow_always' => FilledButton.tonal(onPressed: () => controller.answerPermission(req, '${o['optionId']}'), child: Text('${o['name']}')),
          _ => OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => controller.answerPermission(req, '${o['optionId']}'),
              child: Text('${o['name']}'),
            ),
        },
    ]);
  }
}

class ElicitationCard extends StatelessWidget {
  const ElicitationCard(this.e, {super.key, required this.controller});
  final ElicitationItem e;
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final live = controller.pending[e.requestId];
    final message = e.request?['message'] as String? ?? '需要你的回覆';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: e.resolved ? scheme.surfaceContainerLow : scheme.tertiaryContainer.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.help_outline_rounded, size: 18, color: scheme.tertiary),
            const SizedBox(width: 8),
            Expanded(child: Text(message, style: const TextStyle(fontWeight: FontWeight.w500))),
          ]),
          const SizedBox(height: 4),
          if (e.resolved)
            Text(
              '${switch (e.action) { 'accept' => '已回覆', 'decline' => '已略過', _ => '已取消' }}${e.by != null ? '（${e.by}）' : ''}',
              style: TextStyle(fontSize: 12, color: scheme.outline),
            )
          else if (live != null)
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                icon: const Icon(Icons.edit_note_rounded),
                label: const Text('回答'),
                onPressed: () => showElicitationSheet(context, controller, live),
              ),
            ),
        ]),
      ),
    );
  }
}
