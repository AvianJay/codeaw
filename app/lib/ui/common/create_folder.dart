import 'package:flutter/material.dart';

import '../../app_state.dart';

Future<String?> showCreateFolder(BuildContext context, String parent) {
  FocusManager.instance.primaryFocus?.unfocus();
  return showDialog<String>(
    context: context,
    requestFocus: false,
    builder: (_) => _CreateFolder(parent: parent),
  );
}

class _CreateFolder extends StatefulWidget {
  const _CreateFolder({required this.parent});
  final String parent;
  @override
  State<_CreateFolder> createState() => _CreateFolderState();
}

class _CreateFolderState extends State<_CreateFolder> {
  final _name = TextEditingController();
  final _form = GlobalKey<FormState>();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_busy || !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result =
          await AppScope.read(context).client!.request('_codeaw/fs/mkdir', {
                'path': widget.parent,
                'name': _name.text.trim(),
              })
              as Map;
      if (mounted) Navigator.pop(context, result['path'] as String);
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e.toString().contains('-32601')
              ? '請先更新電腦 bridge，以支援新增資料夾'
              : e.toString(),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('新增資料夾'),
    content: SizedBox(
      width: 340,
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.parent,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 14),
            TextFormField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '資料夾名稱',
                hintText: '例如：新專案',
              ),
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _create(),
              validator: (value) {
                final name = value?.trim() ?? '';
                if (name.isEmpty) return '請輸入資料夾名稱';
                if (name.length > 200 ||
                    RegExp(r'[\\/<>:"|?*\x00-\x1f]').hasMatch(name) ||
                    name == '.' ||
                    name == '..' ||
                    name.endsWith('.') ||
                    RegExp(
                      r'^(con|prn|aux|nul|com[0-9]|lpt[0-9])(?:\.|$)',
                      caseSensitive: false,
                    ).hasMatch(name)) {
                  return '請使用有效的資料夾名稱';
                }
                return null;
              },
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: _busy ? null : _create,
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('建立'),
      ),
    ],
  );
}
