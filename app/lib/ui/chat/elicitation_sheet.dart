import 'package:flutter/material.dart';

import '../../data/session_controller.dart';
import '../common/adaptive.dart';

/// Renders an ACP form elicitation (flat JSON-schema object) and answers it.
Future<void> showElicitationSheet(
  BuildContext context,
  SessionController controller,
  PendingRequest req,
) {
  return showAdaptiveSheet<void>(
    context: context,
    builder: (_) => _ElicitationForm(controller: controller, req: req),
  );
}

class _Choice {
  _Choice(this.value, this.title, this.description);
  final String value;
  final String title;
  final String? description;
}

List<_Choice> _choices(Map<String, dynamic> schema) {
  final out = <_Choice>[];
  for (final key in const ['oneOf', 'anyOf']) {
    final list = schema[key];
    if (list is List) {
      for (final o in list.whereType<Map>()) {
        if (o['const'] != null) {
          out.add(
            _Choice(
              '${o['const']}',
              '${o['title'] ?? o['const']}',
              o['description'] as String?,
            ),
          );
        }
      }
    }
  }
  final enums = schema['enum'];
  if (out.isEmpty && enums is List) {
    final names = schema['enumNames'] is List
        ? schema['enumNames'] as List
        : const [];
    for (var i = 0; i < enums.length; i++) {
      out.add(
        _Choice(
          '${enums[i]}',
          i < names.length ? '${names[i]}' : '${enums[i]}',
          null,
        ),
      );
    }
  }
  return out;
}

class _ElicitationForm extends StatefulWidget {
  const _ElicitationForm({required this.controller, required this.req});
  final SessionController controller;
  final PendingRequest req;

  @override
  State<_ElicitationForm> createState() => _ElicitationFormState();
}

class _ElicitationFormState extends State<_ElicitationForm> {
  final values = <String, Object?>{};
  final texts = <String, TextEditingController>{};
  String? _error;

  Map<String, dynamic> get schema =>
      widget.req.params['requestedSchema'] as Map<String, dynamic>? ?? const {};
  Map<String, dynamic> get props =>
      schema['properties'] as Map<String, dynamic>? ?? const {};
  List<String> get required =>
      (schema['required'] as List? ?? const []).cast<String>();

  @override
  void initState() {
    super.initState();
    props.forEach((key, raw) {
      final p = raw as Map<String, dynamic>;
      if (p.containsKey('default')) values[key] = p['default'];
      if (p['type'] == 'array') values[key] ??= <String>[];
      if (_choices(p).isEmpty &&
          (p['type'] == 'string' ||
              p['type'] == 'number' ||
              p['type'] == 'integer')) {
        texts[key] = TextEditingController(
          text: p['default']?.toString() ?? '',
        );
      }
    });
    widget.req.token.whenCancelled.then((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  void dispose() {
    for (final t in texts.values) {
      t.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final content = <String, Object?>{};
    for (final entry in props.entries) {
      final p = entry.value as Map<String, dynamic>;
      Object? v = values[entry.key];
      final t = texts[entry.key];
      if (t != null) {
        final s = t.text.trim();
        if (p['type'] == 'number') {
          v = s.isEmpty ? null : num.tryParse(s);
        } else if (p['type'] == 'integer') {
          v = s.isEmpty ? null : int.tryParse(s);
        } else {
          v = s.isEmpty ? null : s;
        }
      }
      if (v == null || (v is List && v.isEmpty)) {
        if (required.contains(entry.key)) {
          setState(() => _error = '「${p['title'] ?? entry.key}」必填');
          return;
        }
        continue;
      }
      content[entry.key] = v;
    }
    widget.controller.answerElicitation(widget.req, 'accept', content);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fields = <Widget>[];
    props.forEach((key, raw) {
      final p = raw as Map<String, dynamic>;
      final title = '${p['title'] ?? key}';
      final desc = p['description'] as String?;
      final isCustom = key.endsWith('_custom');
      fields.add(
        Padding(
          padding: const EdgeInsets.only(top: 14, bottom: 4),
          child: Text(
            isCustom ? '其他（自行填寫）' : title,
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
      );
      if (desc != null && !isCustom) {
        fields.add(
          Text(desc, style: TextStyle(fontSize: 12.5, color: scheme.outline)),
        );
      }
      if (p['type'] == 'boolean') {
        fields.add(
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: values[key] == true,
            title: Text(title),
            onChanged: (v) => setState(() => values[key] = v),
          ),
        );
        return;
      }
      if (p['type'] == 'array') {
        final items = p['items'] as Map<String, dynamic>? ?? const {};
        final selected = (values[key] as List?)?.cast<String>() ?? <String>[];
        for (final c in _choices(items)) {
          fields.add(
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              value: selected.contains(c.value),
              title: Text(c.title),
              subtitle: c.description == null ? null : Text(c.description!),
              onChanged: (v) => setState(() {
                final next = [...selected];
                v == true ? next.add(c.value) : next.remove(c.value);
                values[key] = next;
              }),
            ),
          );
        }
        return;
      }
      final choices = _choices(p);
      if (choices.isNotEmpty) {
        fields.add(
          RadioGroup<String>(
            groupValue: values[key] as String?,
            onChanged: (v) => setState(() => values[key] = v),
            child: Column(
              children: [
                for (final c in choices)
                  RadioListTile<String>(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    value: c.value,
                    title: Text(c.title),
                    subtitle: c.description == null
                        ? null
                        : Text(c.description!),
                  ),
              ],
            ),
          ),
        );
        return;
      }
      fields.add(
        TextField(
          controller: texts[key],
          keyboardType: p['type'] == 'number' || p['type'] == 'integer'
              ? TextInputType.number
              : TextInputType.multiline,
          maxLines: p['type'] == 'string' ? null : 1,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: isCustom ? (desc ?? '') : null,
          ),
        ),
      );
    });

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            widget.req.params['message'] as String? ?? '請回答',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          ...fields,
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!, style: TextStyle(color: scheme.error)),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              TextButton(
                onPressed: () {
                  widget.controller.answerElicitation(widget.req, 'cancel');
                  Navigator.of(context).pop();
                },
                child: const Text('取消'),
              ),
              const Spacer(),
              OutlinedButton(
                onPressed: () {
                  widget.controller.answerElicitation(widget.req, 'decline');
                  Navigator.of(context).pop();
                },
                child: const Text('略過'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _submit, child: const Text('送出')),
            ],
          ),
        ],
      ),
    );
  }
}
