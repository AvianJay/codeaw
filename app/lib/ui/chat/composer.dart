import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/mentions.dart';
import '../../data/models.dart';
import '../../data/session_controller.dart';
import '../../data/upload_progress.dart';
import '../../util/image_clipboard.dart';
import '../common/adaptive.dart';
import '../common/widgets.dart';

class _FileUpload {
  _FileUpload(this.name, this.index, this.count);
  final String name;
  final int index;
  final int count;
  int? total;
  int sent = 0;
  bool transferring = false;
  double? get fraction => !transferring || total == null
      ? null
      : total == 0
      ? 1
      : (sent / total!).clamp(0, 1);
}

String _uploadSize(int bytes) => bytes >= 1024 * 1024
    ? '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MiB'
    : bytes >= 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KiB'
    : '$bytes B';

class _UploadProgress extends StatelessWidget {
  const _UploadProgress({required this.upload});
  final _FileUpload upload;

  @override
  Widget build(BuildContext context) {
    final fraction = upload.fraction;
    final status = !upload.transferring
        ? '讀取檔案…'
        : fraction == 1
        ? '等待電腦確認…'
        : '上傳中';
    final sizes = upload.total == null
        ? status
        : '${_uploadSize(upload.sent)} / ${_uploadSize(upload.total!)} · $status';
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      key: const ValueKey('file-upload-progress'),
      padding: const EdgeInsets.fromLTRB(12, 5, 12, 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(
                Icons.cloud_upload_outlined,
                size: 16,
                color: scheme.primary,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  upload.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
              if (upload.count > 1) ...[
                Text(
                  '${upload.index}/${upload.count}',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Text(
                fraction == null ? '準備中' : '${(fraction * 100).floor()}%',
                key: const ValueKey('file-upload-percent'),
                style: TextStyle(fontSize: 12, color: scheme.primary),
              ),
            ],
          ),
          const SizedBox(height: 3),
          LinearProgressIndicator(
            key: const ValueKey('file-upload-bar'),
            value: fraction,
            minHeight: 3,
            borderRadius: BorderRadius.circular(3),
          ),
          const SizedBox(height: 3),
          Text(
            sizes,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.controller,
    this.imageClipboard,
    this.pickFiles,
  });
  final SessionController controller;
  final ImageClipboard? imageClipboard;

  /// Chooses files to send; defaults to the platform file picker.
  final Future<List<XFile>> Function()? pickFiles;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  late final _text = _ComposerTextController(() => c.draftMentions.keys);
  final _focus = FocusNode();
  final _images = <ClipboardImage>[];
  final _uploads = <_Upload>[];
  final _attachMenu = MenuController();
  final _highlightKey = GlobalKey();
  late final ImageClipboard _clipboard;
  late final VoidCallback _stopPasteListener;
  int _readingImages = 0;
  int _attachGeneration = 0;
  bool _pickingFiles = false;
  _FileUpload? _fileUpload;

  // `@` completion: the word before the cursor and the bridge's matches for it.
  ({int start, String query})? _mention;
  List<FileSuggestion> _files = const [];
  bool _searchingFiles = false;
  Timer? _fileSearch;
  int _fileSearchGeneration = 0;
  int _highlight = 0;

  /// Escape hides suggestions until the text changes.
  String? _dismissed;

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
    _text.addListener(_onTextChanged);
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
    _fileSearch?.cancel();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(Composer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, c)) {
      _dismissKeyboard();
      _attachGeneration++;
      _readingImages = 0;
      _pickingFiles = false;
      _fileUpload = null;
      _images.clear();
      _uploads.clear();
      _closeMention();
      if (_attachMenu.isOpen) _attachMenu.close();
      _text.text = c.draft;
    } else if (_text.text != c.draft) {
      _text.value = TextEditingValue(
        text: c.draft,
        selection: TextSelection.collapsed(offset: c.draft.length),
      );
    }
  }

  void _onTextChanged() {
    c.draft = _text.text;
    _highlight = 0;
    _updateMention();
    setState(() {});
  }

  Future<void> _pickImages(ImageSource source) async {
    final target = c;
    final generation = _attachGeneration;
    _dismissKeyboard();
    setState(() => _readingImages++);
    bool current() =>
        mounted && identical(c, target) && generation == _attachGeneration;
    try {
      final picker = ImagePicker();
      final files = source == ImageSource.camera
          ? [
              ?await picker.pickImage(
                source: source,
                maxWidth: 1600,
                maxHeight: 1600,
                imageQuality: 85,
              ),
            ]
          : await picker.pickMultiImage(
              maxWidth: 1600,
              maxHeight: 1600,
              imageQuality: 85,
            );
      for (final file in files) {
        if (!current()) return;
        final image = ClipboardImage(await file.readAsBytes(), _mimeType(file));
        if (current()) setState(() => _images.add(image));
      }
    } catch (_) {
      if (current()) _message('無法讀取圖片，請檢查相簿／相機權限後重試');
    } finally {
      if (current()) setState(() => _readingImages--);
    }
  }

  // Larger images go up as files, so the prompt stays within model limits.
  static const _maxInlineImage = 4 * 1024 * 1024;

  Future<void> _pickFiles() async {
    if (_pickingFiles) return;
    final target = c;
    final generation = _attachGeneration;
    _dismissKeyboard();
    setState(() {
      _pickingFiles = true;
      _readingImages++;
    });
    bool current() =>
        mounted && identical(c, target) && generation == _attachGeneration;
    try {
      final selected = await (widget.pickFiles ?? openFiles)();
      for (var index = 0; index < selected.length; index++) {
        final file = selected[index];
        if (!current()) return;
        final progress = _FileUpload(file.name, index + 1, selected.length);
        setState(() => _fileUpload = progress);
        final size = await file.length();
        if (!current()) return;
        if (size > maxUploadBytes) {
          throw const FormatException('檔案上限為 $uploadLimitLabel');
        }
        if (_supportsImages &&
            size <= _maxInlineImage &&
            RegExp(
              r'\.(png|jpe?g|webp|gif)$',
              caseSensitive: false,
            ).hasMatch(file.name)) {
          try {
            final image = ClipboardImage.fromBytes(await file.readAsBytes());
            if (!current()) return;
            setState(() => _images.add(image));
            continue;
          } on FormatException {
            // Not an image: stream the source as an ordinary file.
          }
        }
        setState(() => progress.total = size);
        final block = await target.client.uploadPickedFile(
          target.sessionId,
          file,
          onProgress: (sent, total) {
            if (!current()) return;
            setState(() {
              progress.sent = sent.clamp(0, total);
              progress.total = total;
              progress.transferring = true;
            });
          },
        );
        if (current()) {
          setState(() => _uploads.add(_Upload(file.name, size)..file = block));
        }
      }
    } catch (error) {
      if (current()) {
        _message('檔案上傳失敗：${error is UploadException ? error.message : error}');
      }
    } finally {
      if (current()) {
        setState(() {
          _readingImages--;
          _pickingFiles = false;
          _fileUpload = null;
        });
      }
    }
  }

  String _mimeType(XFile file) {
    final lower = file.name.toLowerCase();
    return file.mimeType ??
        (lower.endsWith('.png')
            ? 'image/png'
            : lower.endsWith('.webp')
            ? 'image/webp'
            : lower.endsWith('.gif')
            ? 'image/gif'
            : 'image/jpeg');
  }

  Future<bool> _consumePaste(
    Future<ImagePaste> future, {
    bool notifyEmpty = false,
  }) async {
    final target = c;
    final generation = _attachGeneration;
    setState(() => _readingImages++);
    bool current() =>
        mounted && identical(c, target) && generation == _attachGeneration;
    try {
      final paste = await future;
      if (!current() || !_supportsImages) return true;
      if (paste.images.isEmpty) {
        if (notifyEmpty) _message('剪貼簿中沒有圖片');
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
        _message(
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

  void _message(String message) => ScaffoldMessenger.of(
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
      _message('無法貼上圖片，請使用「貼上剪貼簿圖片」或從相簿選擇');
    }
  }

  void _send({bool queue = false}) {
    if (_readingImages > 0 || _uploads.any((u) => u.file == null)) return;
    final text = _text.text.trim();
    if (text.isEmpty && _images.isEmpty && _uploads.isEmpty) return;
    final blocks = <Map<String, dynamic>>[
      if (text.isNotEmpty) ...promptBlocks(text, c.draftMentions),
      for (final upload in _uploads) upload.file!,
      for (final img in _images)
        {
          'type': 'image',
          'mimeType': img.mimeType,
          'data': base64Encode(img.bytes),
        },
    ];
    final target = c;
    final images = List<ClipboardImage>.of(_images);
    final uploads = List<_Upload>.of(_uploads);
    final mentions = Map<String, String>.of(c.draftMentions);
    unawaited(
      target.send(blocks, queue: queue).then((sent) {
        if (!sent &&
            mounted &&
            identical(c, target) &&
            _text.text.isEmpty &&
            _images.isEmpty &&
            _uploads.isEmpty) {
          c.draftMentions.addAll(mentions);
          _text.text = text;
          setState(() {
            _images.addAll(images);
            _uploads.addAll(uploads);
          });
        }
      }),
    );
    c.draftMentions.clear();
    _text.clear();
    setState(() {
      _images.clear();
      _uploads.clear();
    });
  }

  /// Replaces `start..end` and puts the cursor after the inserted text.
  void _replace(int start, int end, String insert) {
    final text = _text.text.replaceRange(start, end, insert);
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: start + insert.length),
    );
  }

  List<Map<String, dynamic>> get _commands {
    final t = _text.text;
    if (_dismissed == t ||
        !t.startsWith('/') ||
        t.contains(' ') ||
        t.contains('\n')) {
      return const [];
    }
    final q = t.substring(1).toLowerCase();
    return c.timeline.commands
        .where((cmd) => '${cmd['name']}'.toLowerCase().contains(q))
        .take(30)
        .toList();
  }

  void _pickCommand(Map<String, dynamic> cmd) {
    final hint = (cmd['input'] as Map?)?['hint'];
    _replace(0, _text.text.length, '/${cmd['name']}${hint != null ? ' ' : ''}');
    _focus.requestFocus();
  }

  void _startCommand() {
    _replace(0, _text.text.length, '/');
    _focus.requestFocus();
  }

  /// The `@word` being typed at the cursor, unless it is a mention already picked.
  ({int start, String query})? _mentionAt(TextEditingValue value) {
    final cursor = value.selection;
    if (c.cwd.isEmpty ||
        !cursor.isValid ||
        !cursor.isCollapsed ||
        cursor.baseOffset > value.text.length) {
      return null;
    }
    final before = value.text.substring(0, cursor.baseOffset);
    final start = before.lastIndexOf('@');
    if (start < 0 || !mentionCanStartAt(before, start)) return null;
    final query = before.substring(start + 1);
    if (query.contains(RegExp(r'\s')) || c.draftMentions.containsKey(query)) {
      return null;
    }
    return (start: start, query: query);
  }

  void _updateMention() {
    final next = _mentionAt(_text.value);
    if (next == _mention) return;
    _mention = next;
    _fileSearch?.cancel();
    final generation = ++_fileSearchGeneration;
    if (next == null) {
      _files = const [];
      _searchingFiles = false;
      return;
    }
    // Earlier matches stay listed until the bridge answers for this query.
    _searchingFiles = true;
    final target = c;
    _fileSearch = Timer(const Duration(milliseconds: 120), () async {
      var files = const <FileSuggestion>[];
      try {
        files = await target.searchFiles(next.query);
      } catch (_) {
        // Offline or not allowed: show no matches rather than an error.
      }
      if (!mounted ||
          generation != _fileSearchGeneration ||
          !identical(target, c)) {
        return;
      }
      setState(() {
        _files = files;
        _searchingFiles = false;
        _highlight = 0;
      });
    });
  }

  void _closeMention() {
    _fileSearch?.cancel();
    _fileSearchGeneration++;
    _mention = null;
    _files = const [];
    _searchingFiles = false;
    _highlight = 0;
  }

  /// Folders open for further completion unless [folder] mentions the folder itself.
  void _pickFile(FileSuggestion file, {bool folder = false}) {
    final mention = _mention;
    final cursor = _text.selection;
    if (mention == null || !cursor.isValid) return;
    final complete = !file.directory || folder;
    if (complete) c.draftMentions[file.token] = fileUriOf(file.path);
    _replace(
      mention.start,
      cursor.baseOffset,
      '@${file.token}${complete ? ' ' : ''}',
    );
    _focus.requestFocus();
  }

  void _startMention() {
    final value = _text.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final space = mentionCanStartAt(value.text, selection.start) ? '' : ' ';
    _replace(selection.start, selection.end, '$space@');
    _focus.requestFocus();
  }

  bool get _mentioning => _mention != null && _dismissed != _text.text;

  int get _suggestionCount {
    final commands = _commands.length;
    return commands > 0 ? commands : (_mentioning ? _files.length : 0);
  }

  void _acceptSuggestion(int index) {
    final commands = _commands;
    if (commands.isNotEmpty) {
      _pickCommand(commands[index]);
    } else if (_mentioning && index < _files.length) {
      _pickFile(_files[index]);
    }
  }

  void _moveHighlight(int delta, int count) {
    setState(() => _highlight = (_highlight + delta) % count);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _highlightKey.currentContext;
      if (target == null) return;
      Scrollable.ensureVisible(
        target,
        alignmentPolicy: delta > 0
            ? ScrollPositionAlignmentPolicy.keepVisibleAtEnd
            : ScrollPositionAlignmentPolicy.keepVisibleAtStart,
      );
    });
  }

  /// Arrow keys, Tab/Enter and Escape drive the suggestion list on hardware keyboards.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        keyboard.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _attachMenu.isOpen) {
      _attachMenu.close();
      return KeyEventResult.handled;
    }
    final count = _suggestionCount;
    if (count == 0 && !_mentioning) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        setState(() => _dismissed = _text.text);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown when count > 0:
        _moveHighlight(1, count);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp when count > 0:
        _moveHighlight(-1, count);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab ||
              LogicalKeyboardKey.enter ||
              LogicalKeyboardKey.numpadEnter
          when count > 0:
        _acceptSuggestion(_highlight.clamp(0, count - 1));
        return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  List<_AttachAction?> _attachActions() {
    final images = _supportsImages;
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    final camera =
        images &&
        mobile &&
        ImagePicker().supportsImageSource(ImageSource.camera);
    final mention = c.cwd.isNotEmpty;
    // Commands only work at the start of an otherwise empty message.
    final command = c.timeline.commands.isNotEmpty && _text.text.isEmpty;
    return [
      if (images)
        _AttachAction(
          Icons.photo_library_outlined,
          '從相簿選擇',
          () => _pickImages(ImageSource.gallery),
        ),
      if (camera)
        _AttachAction(
          Icons.photo_camera_outlined,
          '拍照',
          () => _pickImages(ImageSource.camera),
        ),
      if (images)
        _AttachAction(
          Icons.content_paste_rounded,
          '貼上剪貼簿圖片',
          () => _pasteImage(notifyEmpty: true),
        ),
      if (images) null,
      _AttachAction(Icons.attach_file_rounded, '上傳檔案', _pickFiles),
      if (mention)
        _AttachAction(
          Icons.alternate_email_rounded,
          '提及檔案',
          _startMention,
          shortcut: '@',
        ),
      if (command)
        _AttachAction(Icons.bolt_rounded, '斜線指令', _startCommand, shortcut: '/'),
    ];
  }

  List<Widget> _fileTiles(ColorScheme scheme) {
    if (_files.isEmpty) {
      return [
        ListTile(
          dense: true,
          leading: _searchingFiles
              ? const SizedBox.square(
                  dimension: 20,
                  child: Padding(
                    padding: EdgeInsets.all(2),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : Icon(Icons.search_off_rounded, size: 20, color: scheme.outline),
          title: Text(
            _searchingFiles ? '搜尋檔案中…' : '找不到符合的檔案',
            style: TextStyle(color: scheme.outline),
          ),
        ),
      ];
    }
    return [
      for (final (i, file) in _files.indexed)
        ListTile(
          key: i == _highlight
              ? _highlightKey
              : ValueKey('mention:${file.token}'),
          dense: true,
          selected: i == _highlight,
          leading: Icon(
            file.directory ? Icons.folder_rounded : fileIcon(file.name),
            size: 20,
            color: file.directory ? scheme.primary : scheme.outline,
          ),
          title: Text(
            file.directory ? '${file.name}/' : file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: file.relative.contains('/')
              ? Text(
                  file.relative.substring(0, file.relative.lastIndexOf('/')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                )
              : null,
          trailing: file.directory
              ? IconButton(
                  tooltip: '提及這個資料夾',
                  icon: const Icon(Icons.alternate_email_rounded, size: 18),
                  onPressed: () => _pickFile(file, folder: true),
                )
              : null,
          onTap: () => _pickFile(file),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final running = c.running;
    final agent = c.agent;
    final commands = _commands;
    final attachments = _attachActions();
    final canSend =
        c.client.isOnline &&
        (!c.desktopSync || c.desktopConnected) &&
        _readingImages == 0 &&
        !_uploads.any((u) => u.file == null) &&
        (_text.text.trim().isNotEmpty ||
            _images.isNotEmpty ||
            _uploads.isNotEmpty);
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
                  if (commands.isNotEmpty)
                    _SuggestionList(
                      children: [
                        for (final (i, cmd) in commands.indexed)
                          ListTile(
                            key: i == _highlight ? _highlightKey : null,
                            dense: true,
                            selected: i == _highlight,
                            title: Text(
                              '/${cmd['name']}',
                              style: const TextStyle(fontFamily: 'monospace'),
                            ),
                            subtitle: Text(
                              '${cmd['description'] ?? ''}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => _pickCommand(cmd),
                          ),
                      ],
                    )
                  else if (_mentioning)
                    _SuggestionList(children: _fileTiles(scheme)),
                  if (!(compact && keyboard)) ConfigBar(controller: c),
                  if (_readingImages > 0 && _fileUpload == null)
                    const LinearProgressIndicator(),
                  if (_fileUpload case final progress?)
                    _UploadProgress(upload: progress),
                  if (_images.isNotEmpty || _uploads.isNotEmpty)
                    SizedBox(
                      height: compact ? 48 : 72,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        children: [
                          for (final upload in _uploads)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: _UploadChip(
                                upload: upload,
                                compact: compact,
                                onRemove: () =>
                                    setState(() => _uploads.remove(upload)),
                              ),
                            ),
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
                        if (attachments.isNotEmpty)
                          _AttachButton(
                            controller: _attachMenu,
                            actions: attachments,
                          )
                        else
                          const SizedBox(width: 8),
                        Expanded(
                          child: Focus(
                            canRequestFocus: false,
                            skipTraversal: true,
                            onKeyEvent: _onKey,
                            child: TextField(
                              controller: _text,
                              focusNode: _focus,
                              minLines: 1,
                              maxLines: compact ? 2 : 6,
                              onTapOutside: (_) => _dismissKeyboard(),
                              textInputAction: TextInputAction.newline,
                              contentInsertionConfiguration: _supportsImages
                                  ? ContentInsertionConfiguration(
                                      allowedMimeTypes:
                                          ClipboardImage.mimeTypes,
                                      onContentInserted: _insertKeyboardImage,
                                    )
                                  : null,
                              decoration: InputDecoration(
                                hintText: running
                                    ? (agent?.steering ?? false
                                          ? '補充指示，插入目前回合'
                                          : '下一則，排在目前回合後')
                                    : '輸入訊息，@ 檔案、/ 指令',
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

/// Picked `@` mentions are drawn in the accent color: they are sent as file links.
class _ComposerTextController extends TextEditingController {
  _ComposerTextController(this._mentions);
  final Iterable<String> Function() _mentions;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final ranges = mentionRanges(text, _mentions());
    if (ranges.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final accent = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      fontWeight: FontWeight.w600,
    );
    final composing = withComposing && value.isComposingRangeValid
        ? value.composing
        : TextRange.empty;
    final cuts = {
      0,
      text.length,
      for (final r in ranges) ...[r.start, r.end],
      if (!composing.isCollapsed) ...[composing.start, composing.end],
    }.toList()..sort();
    final children = <TextSpan>[];
    for (var i = 0; i + 1 < cuts.length; i++) {
      final (start, end) = (cuts[i], cuts[i + 1]);
      final mention = ranges.any((r) => r.start <= start && end <= r.end);
      final composed =
          !composing.isCollapsed &&
          composing.start <= start &&
          end <= composing.end;
      children.add(
        TextSpan(
          text: text.substring(start, end),
          style: (mention ? accent : const TextStyle()).copyWith(
            decoration: composed ? TextDecoration.underline : null,
          ),
        ),
      );
    }
    return TextSpan(style: style, children: children);
  }
}

class _AttachAction {
  const _AttachAction(this.icon, this.label, this.onSelected, {this.shortcut});
  final IconData icon;
  final String label;
  final VoidCallback onSelected;

  /// The character that starts the same action from the keyboard.
  final String? shortcut;
}

/// "+" opens its menu above itself, leaving the text field and keyboard uncovered.
class _AttachButton extends StatelessWidget {
  const _AttachButton({required this.controller, required this.actions});
  final MenuController controller;

  /// `null` separates groups.
  final List<_AttachAction?> actions;

  @override
  Widget build(BuildContext context) {
    return RawMenuAnchor(
      controller: controller,
      overlayBuilder: (context, info) =>
          _AttachMenu(info: info, controller: controller, actions: actions),
      builder: (context, controller, _) => IconButton(
        tooltip: '附加',
        isSelected: controller.isOpen,
        icon: const Icon(Icons.add_rounded),
        selectedIcon: const Icon(Icons.close_rounded),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

class _AttachMenu extends StatelessWidget {
  const _AttachMenu({
    required this.info,
    required this.controller,
    required this.actions,
  });
  final RawMenuOverlayInfo info;
  final MenuController controller;
  final List<_AttachAction?> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final anchor = info.anchorRect;
    final width = math.min(260.0, info.overlaySize.width - 16);
    final top = MediaQuery.paddingOf(context).top + 8;
    return Positioned(
      left: anchor.left.clamp(
        8.0,
        math.max(8.0, info.overlaySize.width - width - 8),
      ),
      bottom: info.overlaySize.height - anchor.top + 6,
      width: width,
      child: TapRegion(
        groupId: info.tapRegionGroupId,
        onTapOutside: (_) => controller.close(),
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0, end: 1),
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 8 * (1 - t)),
              child: child,
            ),
          ),
          child: Material(
            elevation: 3,
            color: scheme.surfaceContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: math.max(120, anchor.top - 6 - top),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final action in actions)
                      if (action == null)
                        const Divider(height: 9, indent: 12, endIndent: 12)
                      else
                        MenuItemButton(
                          requestFocusOnHover: false,
                          leadingIcon: Icon(action.icon),
                          trailingIcon: action.shortcut == null
                              ? null
                              : Text(
                                  action.shortcut!,
                                  style: TextStyle(
                                    color: scheme.outline,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                          onPressed: () {
                            controller.close();
                            action.onSelected();
                          },
                          child: Text(action.label),
                        ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A file on its way to the bridge ([file] is null), or stored there.
class _Upload {
  _Upload(this.name, this.size);
  final String name;
  final int size;
  Map<String, dynamic>? file;
}

class _UploadChip extends StatelessWidget {
  const _UploadChip({
    required this.upload,
    required this.onRemove,
    this.compact = false,
  });
  final _Upload upload;
  final VoidCallback onRemove;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        Container(
          height: compact ? 36 : 60,
          constraints: const BoxConstraints(maxWidth: 200),
          padding: EdgeInsets.fromLTRB(
            10,
            compact ? 4 : 8,
            22,
            compact ? 4 : 8,
          ),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (upload.file == null)
                const SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Icon(fileIcon(upload.name), size: 22, color: scheme.primary),
              const SizedBox(width: 8),
              Flexible(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      upload.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (!compact)
                      Text(
                        upload.file == null ? '上傳中…' : formatBytes(upload.size),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Positioned(
          right: -10,
          top: -10,
          child: IconButton(
            iconSize: 16,
            tooltip: '移除檔案',
            icon: const Icon(Icons.cancel_rounded),
            onPressed: onRemove,
          ),
        ),
      ],
    );
  }
}

class _SuggestionList extends StatelessWidget {
  const _SuggestionList({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxHeight: 220),
    child: ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: children,
    ),
  );
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
