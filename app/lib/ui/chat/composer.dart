import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/models.dart';
import '../../data/session_controller.dart';
import '../../util/image_clipboard.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';

enum _AttachmentAction { file, gallery, camera, paste }

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    this.imageClipboard,
    this.selectFiles,
  });
  final SessionController controller;
  final ImageClipboard? imageClipboard;
  final Future<List<XFile>> Function()? selectFiles;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _images = <ClipboardImage>[];
  final _files = <Map<String, dynamic>>[];
  late final ImageClipboard _clipboard;
  late final VoidCallback _stopPasteListener;
  int _readingImages = 0;
  int _pasteGeneration = 0;

  SessionController get c => widget.controller;
  bool get _supportsImages => c.desktopSync || (c.agent?.image ?? true);

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    _clipboard = widget.imageClipboard ?? ImageClipboard();
    _stopPasteListener = _clipboard.listen(
      canPaste: () => mounted && _focus.hasFocus && _supportsImages,
      onPaste: (paste) => unawaited(_consumePaste(paste)),
    );
    _text.text = c.draft;
    _text.addListener(() {
      c.draft = _text.text;
      setState(() {});
    });
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  void _dismissKeyboard() {
    _focus.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
  }

  @override
  void dispose() {
    _stopPasteListener();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, c)) {
      _dismissKeyboard();
      _pasteGeneration++;
      _readingImages = 0;
      _images.clear();
      _files.clear();
      _text.text = c.draft;
    } else if (_text.text != c.draft) {
      _text.value = TextEditingValue(
        text: c.draft,
        selection: TextSelection.collapsed(offset: c.draft.length),
      );
    }
  }

  Future<void> _pick(ImageSource source) async {
    final target = c;
    _dismissKeyboard();
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 85,
      );
      if (file == null || !mounted || !identical(c, target)) return;
      final bytes = await file.readAsBytes();
      final lower = file.name.toLowerCase();
      final mime =
          file.mimeType ??
          (lower.endsWith('.png')
              ? 'image/png'
              : lower.endsWith('.webp')
              ? 'image/webp'
              : lower.endsWith('.gif')
              ? 'image/gif'
              : 'image/jpeg');
      if (mounted && identical(c, target)) {
        setState(() => _images.add(ClipboardImage(bytes, mime)));
      }
    } catch (_) {
      if (mounted && identical(c, target)) {
        _pasteMessage('無法讀取圖片，請檢查相簿／相機權限後重試');
      }
    }
  }

  Future<void> _pickFiles() async {
    final target = c;
    _dismissKeyboard();
    final generation = _pasteGeneration;
    setState(() => _readingImages++);
    bool current() =>
        mounted && identical(c, target) && generation == _pasteGeneration;
    try {
      final selected = await (widget.selectFiles?.call() ?? openFiles());
      for (final file in selected) {
        if (!current()) return;
        if (await file.length() > 20 * 1024 * 1024) {
          throw const FormatException('檔案上限為 20 MiB');
        }
        final bytes = await file.readAsBytes();
        if (!current()) return;
        final block = await target.client.uploadFile(
          target.sessionId,
          file.name,
          bytes,
        );
        if (current()) setState(() => _files.add(block));
      }
    } catch (error) {
      if (current()) _pasteMessage('檔案上傳失敗：$error');
    } finally {
      if (current()) setState(() => _readingImages--);
    }
  }

  Future<bool> _consumePaste(
    Future<ImagePaste> future, {
    bool notifyEmpty = false,
  }) async {
    final target = c;
    final generation = _pasteGeneration;
    setState(() => _readingImages++);
    bool current() =>
        mounted && identical(c, target) && generation == _pasteGeneration;
    try {
      final paste = await future;
      if (!current() || !_supportsImages) return true;
      if (paste.images.isEmpty) {
        if (notifyEmpty) _pasteMessage('剪貼簿中沒有圖片');
        return false;
      }
      setState(() => _images.addAll(paste.images));
      if (paste.text.isNotEmpty) {
        final value = _text.value;
        _text.value = value.replaced(
          value.selection.isValid
              ? value.selection
              : TextRange.collapsed(value.text.length),
          paste.text,
        );
      }
      return true;
    } catch (_) {
      if (current()) {
        _pasteMessage(
          _clipboard.usesPasteEvents
              ? '無法讀取剪貼簿圖片，請在輸入框使用 Ctrl／⌘＋V 貼上'
              : '無法貼上剪貼簿圖片，請重新複製圖片後再貼上',
        );
      }
      return !current();
    } finally {
      if (current()) setState(() => _readingImages--);
    }
  }

  void _pasteMessage(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<bool> _pasteImage({bool notifyEmpty = false}) {
    if (!_supportsImages) return Future.value(false);
    return _consumePaste(_clipboard.read(), notifyEmpty: notifyEmpty);
  }

  void _insertKeyboardImage(KeyboardInsertedContent content) {
    if (!_supportsImages ||
        !ClipboardImage.mimeTypes.contains(content.mimeType)) {
      return;
    }
    try {
      final bytes = content.data;
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('Missing image bytes');
      }
      setState(() => _images.add(ClipboardImage.fromBytes(bytes)));
    } catch (_) {
      _pasteMessage('無法貼上圖片，請使用「貼上剪貼簿圖片」或從相簿選擇');
    }
  }

  void _send({bool queue = false}) {
    if (_readingImages > 0) return;
    final text = _text.text.trim();
    if (text.isEmpty && _images.isEmpty && _files.isEmpty) return;
    final blocks = <Map<String, dynamic>>[
      if (text.isNotEmpty) {'type': 'text', 'text': text},
      for (final img in _images)
        {
          'type': 'image',
          'mimeType': img.mimeType,
          'data': base64Encode(img.bytes),
        },
      ..._files,
    ];
    final target = c;
    final images = List<ClipboardImage>.of(_images);
    final files = List<Map<String, dynamic>>.of(_files);
    unawaited(
      target.send(blocks, queue: queue).then((sent) {
        if (!sent &&
            mounted &&
            identical(c, target) &&
            _text.text.isEmpty &&
            _images.isEmpty &&
            _files.isEmpty) {
          _text.text = text;
          setState(() {
            _images.addAll(images);
            _files.addAll(files);
          });
        }
      }),
    );
    _text.clear();
    setState(() {
      _images.clear();
      _files.clear();
    });
  }

  List<Map<String, dynamic>> get _suggestions {
    final t = _text.text;
    if (!t.startsWith('/') || t.contains(' ') || t.contains('\n')) {
      return const [];
    }
    final q = t.substring(1).toLowerCase();
    return c.timeline.commands
        .where((cmd) => '${cmd['name']}'.toLowerCase().contains(q))
        .take(30)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = c.running;
    final agent = c.agent;
    final suggestions = _suggestions;
    final canSend =
        c.client.isOnline &&
        (!c.desktopSync || c.desktopConnected) &&
        _readingImages == 0 &&
        (_text.text.trim().isNotEmpty ||
            _images.isNotEmpty ||
            _files.isNotEmpty);
    final wide = useWideLayout(context);
    // Scaffold removes body viewInsets after resizing; read the actual view
    // so the Done control and compact composer still see the keyboard.
    final view = View.of(context);
    final keyboardInset = view.viewInsets.bottom / view.devicePixelRatio;
    final keyboard = keyboardInset > 0;
    final compact = MediaQuery.sizeOf(context).height - keyboardInset < 430;
    return Padding(
      padding: wide
          ? const EdgeInsets.fromLTRB(16, 8, 16, 16)
          : EdgeInsets.zero,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.enter, control: true): () {
            if (canSend) _send();
          },
          const SingleActivator(LogicalKeyboardKey.enter, meta: true): () {
            if (canSend) _send();
          },
        },
        child: Actions(
          actions: {
            PasteTextIntent: _ImagePasteAction(
              canPasteImage: () =>
                  _supportsImages && !_clipboard.usesPasteEvents,
              pasteImage: _pasteImage,
            ),
          },
          child: Material(
            color: scheme.surfaceContainerLow,
            shape: wide
                ? RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: scheme.outlineVariant.withValues(alpha: .7),
                    ),
                  )
                : null,
            clipBehavior: Clip.antiAlias,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (suggestions.isNotEmpty)
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: ListView(
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        children: [
                          for (final cmd in suggestions)
                            ListTile(
                              dense: true,
                              title: Text(
                                '/${cmd['name']}',
                                style: const TextStyle(fontFamily: 'monospace'),
                              ),
                              subtitle: Text(
                                '${cmd['description'] ?? ''}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                final hint = (cmd['input'] as Map?)?['hint'];
                                _text.text =
                                    '/${cmd['name']}${hint != null ? ' ' : ''}';
                                _text.selection = TextSelection.collapsed(
                                  offset: _text.text.length,
                                );
                                _focus.requestFocus();
                              },
                            ),
                        ],
                      ),
                    ),
                  if (!(compact && keyboard)) ConfigBar(controller: c),
                  if (_readingImages > 0) const LinearProgressIndicator(),
                  if (_files.isNotEmpty)
                    SizedBox(
                      height: 40,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final file in _files)
                            Padding(
                              padding: const EdgeInsets.only(left: 6),
                              child: InputChip(
                                avatar: const Icon(Icons.attach_file, size: 16),
                                label: Text(
                                  '${file['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                                onDeleted: () =>
                                    setState(() => _files.remove(file)),
                              ),
                            ),
                        ],
                      ),
                    ),
                  if (_images.isNotEmpty)
                    SizedBox(
                      height: compact ? 48 : 72,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        children: [
                          for (final img in _images)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: Stack(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: Image.memory(
                                      img.bytes,
                                      width: 60,
                                      height: 60,
                                      fit: BoxFit.cover,
                                    ),
                                  ),
                                  Positioned(
                                    right: -10,
                                    top: -10,
                                    child: IconButton(
                                      iconSize: 16,
                                      tooltip: '移除圖片',
                                      icon: const Icon(Icons.cancel_rounded),
                                      onPressed: () =>
                                          setState(() => _images.remove(img)),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 8, 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        PopupMenuButton<_AttachmentAction>(
                          icon: Icon(
                            Icons.add_rounded,
                            color: scheme.onSurfaceVariant,
                          ),
                          tooltip: '附加檔案或圖片',
                          onOpened: _dismissKeyboard,
                          onSelected: (action) async {
                            switch (action) {
                              case _AttachmentAction.file:
                                await _pickFiles();
                              case _AttachmentAction.gallery:
                                await _pick(ImageSource.gallery);
                              case _AttachmentAction.camera:
                                await _pick(ImageSource.camera);
                              case _AttachmentAction.paste:
                                await _pasteImage(notifyEmpty: true);
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: _AttachmentAction.file,
                              child: Text('選擇檔案（20 MiB 上限）'),
                            ),
                            if (_supportsImages)
                              const PopupMenuItem(
                                value: _AttachmentAction.gallery,
                                child: Text('從相簿選擇'),
                              ),
                            if (_supportsImages)
                              const PopupMenuItem(
                                value: _AttachmentAction.camera,
                                child: Text('拍照'),
                              ),
                            if (_supportsImages)
                              const PopupMenuItem(
                                value: _AttachmentAction.paste,
                                child: Text('貼上剪貼簿圖片'),
                              ),
                          ],
                        ),
                        Expanded(
                          child: TextField(
                            controller: _text,
                            focusNode: _focus,
                            minLines: 1,
                            maxLines: compact ? 2 : 6,
                            onTapOutside: (_) => _dismissKeyboard(),
                            textInputAction: TextInputAction.newline,
                            contentInsertionConfiguration: _supportsImages
                                ? ContentInsertionConfiguration(
                                    allowedMimeTypes: ClipboardImage.mimeTypes,
                                    onContentInserted: _insertKeyboardImage,
                                  )
                                : null,
                            decoration: InputDecoration(
                              hintText: running
                                  ? (agent?.steering ?? false
                                        ? '補充指示，插入目前回合'
                                        : '下一則，排在目前回合後')
                                  : '輸入訊息，/ 開頭是指令',
                              hintMaxLines: 1,
                              filled: true,
                              fillColor: scheme.surfaceContainerLowest,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: .7,
                                  ),
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: scheme.outlineVariant.withValues(
                                    alpha: .7,
                                  ),
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(14),
                                borderSide: BorderSide(
                                  color: scheme.primary.withValues(alpha: .6),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (_focus.hasFocus && keyboard)
                          IconButton(
                            tooltip: '收起鍵盤',
                            icon: const Icon(Icons.keyboard_hide_rounded),
                            onPressed: _dismissKeyboard,
                          ),
                        if (running)
                          IconButton.filledTonal(
                            tooltip: '停止',
                            icon: const Icon(Icons.stop_rounded),
                            onPressed: c.cancel,
                          ),
                        TooltipTheme(
                          data: const TooltipThemeData(
                            triggerMode: TooltipTriggerMode.manual,
                          ),
                          child: GestureDetector(
                            onLongPress: canSend && running
                                ? () => _send(queue: true)
                                : null,
                            child: IconButton.filled(
                              style: IconButton.styleFrom(
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              tooltip: running ? '送出（長按＝排隊）' : '送出',
                              icon: const Icon(Icons.arrow_upward_rounded),
                              onPressed: canSend ? _send : null,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (wide)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        'Ctrl / ⌘ + Enter 傳送 · Enter 換行',
                        style: TextStyle(fontSize: 11, color: scheme.outline),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Preserve Flutter's selection, text paste and undo behavior when there is no image.
class _ImagePasteAction extends Action<PasteTextIntent> {
  _ImagePasteAction({required this.canPasteImage, required this.pasteImage});
  final bool Function() canPasteImage;
  final Future<bool> Function() pasteImage;

  @override
  bool consumesKey(PasteTextIntent intent) =>
      canPasteImage() || (callingAction?.consumesKey(intent) ?? false);

  @override
  Object? invoke(PasteTextIntent intent) {
    final fallback = callingAction;
    if (!canPasteImage()) return fallback?.invoke(intent);
    unawaited(
      pasteImage().then((handled) {
        if (!handled) fallback?.invoke(intent);
      }),
    );
    return null;
  }
}

/// Chips for the session's config options (mode, model, reasoning…), plus context usage.
class ConfigBar extends StatelessWidget {
  const ConfigBar({super.key, required this.controller});
  final SessionController controller;

  @override
  Widget build(BuildContext context) {
    final options = controller.configOptions;
    final usage = controller.timeline.usage;
    if (options.isEmpty && usage == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        children: [
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: o.type == 'boolean'
                  ? FilterChip(
                      visualDensity: VisualDensity.compact,
                      label: Text(o.name, style: const TextStyle(fontSize: 12)),
                      selected: o.currentValue == true,
                      onSelected: (v) => controller.setConfig(o, v),
                    )
                  : ActionChip(
                      visualDensity: VisualDensity.compact,
                      backgroundColor: Colors.transparent,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(9),
                      ),
                      avatar: o.category == 'model'
                          ? AgentAvatar(agentId: controller.agentId, size: 18)
                          : Icon(
                              _categoryIcon(o),
                              size: 15,
                              color: scheme.onSurfaceVariant,
                            ),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            o.currentLabel,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            Icons.keyboard_arrow_down_rounded,
                            size: 13,
                            color: scheme.outline,
                          ),
                        ],
                      ),
                      onPressed: () => _pickValue(context, o),
                    ),
            ),
          if (usage != null &&
              usage['size'] is num &&
              (usage['size'] as num) > 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Text(
                  '${compactTokens(usage['used'] as num? ?? 0)}/${compactTokens(usage['size'] as num)}'
                  '${usage['cost'] is Map ? ' · \$${((usage['cost'] as Map)['amount'] as num?)?.toStringAsFixed(2) ?? ''}' : ''}',
                  style: TextStyle(fontSize: 11.5, color: scheme.outline),
                ),
              ),
            ),
        ],
      ),
    );
  }

  IconData _categoryIcon(ConfigOption option) =>
      option.id == 'collaboration_mode'
      ? Icons.route_outlined
      : switch (option.category) {
          'mode' => Icons.shield_outlined,
          'model' => Icons.memory_rounded,
          'thought_level' => Icons.psychology_outlined,
          'model_config' => Icons.tune_rounded,
          _ => Icons.settings_outlined,
        };

  Future<void> _pickValue(BuildContext context, ConfigOption o) async {
    final values = o.values;
    final picked = await showAdaptiveSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
          ),
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(o.name, style: Theme.of(ctx).textTheme.titleMedium),
              ),
              if (o.description != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Text(
                    o.description!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.outline),
                  ),
                ),
              if (o.category == 'model' || o.id == 'model')
                ListTile(
                  leading: const Icon(Icons.edit_outlined),
                  title: const Text('自訂模型名稱'),
                  onTap: () async {
                    final value = await showDialog<String>(
                      context: ctx,
                      builder: (_) => _CustomModelDialog(
                        currentValue: o.currentValue as String? ?? '',
                      ),
                    );
                    if (ctx.mounted && value != null) {
                      Navigator.pop(ctx, value);
                    }
                  },
                ),
              RadioGroup<String>(
                groupValue: '${o.currentValue}',
                onChanged: (v) => Navigator.pop(ctx, v),
                child: Column(
                  children: [
                    for (var i = 0; i < values.length; i++) ...[
                      if (values[i].group != null &&
                          (i == 0 || values[i - 1].group != values[i].group))
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 12, 20, 2),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              values[i].group!,
                              style: Theme.of(ctx).textTheme.labelMedium,
                            ),
                          ),
                        ),
                      RadioListTile<String>(
                        value: values[i].value,
                        title: Text(values[i].name),
                        subtitle: values[i].description == null
                            ? null
                            : Text(
                                values[i].description!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != '${o.currentValue}') {
      await controller.setConfig(o, picked);
    }
  }
}

class _CustomModelDialog extends StatefulWidget {
  const _CustomModelDialog({required this.currentValue});
  final String currentValue;

  @override
  State<_CustomModelDialog> createState() => _CustomModelDialogState();
}

class _CustomModelDialogState extends State<_CustomModelDialog> {
  late final TextEditingController _text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.currentValue)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.currentValue.length,
      );
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('自訂模型名稱'),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: TextField(
        controller: _text,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: '模型名稱',
          helperText: '請輸入目前代理支援的模型 ID。',
          helperMaxLines: 2,
        ),
        onSubmitted: (_) => _submit(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: _text,
        builder: (context, value, _) => FilledButton(
          onPressed: value.text.trim().isEmpty ? null : _submit,
          child: const Text('套用'),
        ),
      ),
    ],
  );
}
