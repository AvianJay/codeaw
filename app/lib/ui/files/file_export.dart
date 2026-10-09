import 'dart:async';

import 'package:flutter/material.dart';

import '../../acp/jsonrpc.dart';
import '../../app_state.dart';
import '../../data/bridge_client.dart';
import '../../data/file_download.dart';
import '../../data/file_download_web.dart'
    if (dart.library.io) '../../data/file_download_io.dart'
    as platform;
import '../../data/models.dart';
import '../common/widgets.dart';

enum FileExportAction { save, share }

Future<void> showFileExport(
  BuildContext context, {
  required String path,
  List<String>? paths,
  FileExportAction action = FileExportAction.save,
}) async {
  final client = AppScope.read(context).client;
  if (client == null || !client.isOnline) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('請先連上電腦')));
    return;
  }
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FileExportDialog(
      client: client,
      path: path,
      paths: paths,
      action: action,
    ),
  );
}

class _FileExportDialog extends StatefulWidget {
  const _FileExportDialog({
    required this.client,
    required this.path,
    required this.paths,
    required this.action,
  });
  final BridgeClient client;
  final String path;
  final List<String>? paths;
  final FileExportAction action;
  @override
  State<_FileExportDialog> createState() => _FileExportDialogState();
}

class _FileExportDialogState extends State<_FileExportDialog> {
  final _cancel = CancelToken();
  DownloadedFile? _file;
  int _received = 0;
  int? _total;
  String? _error;
  bool _exporting = false;
  int _lastProgress = 0;
  String get _name =>
      '${folderName(widget.path)}${widget.paths == null ? '' : '.zip'}';
  bool get _busy => _file == null && _error == null;

  @override
  void initState() {
    super.initState();
    unawaited(_download());
  }

  @override
  void dispose() {
    _cancel.cancel();
    unawaited(_file?.dispose());
    super.dispose();
  }

  Future<void> _download() async {
    void progress(int received, int? total) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (!mounted || (received != total && now - _lastProgress < 100)) return;
      _lastProgress = now;
      setState(() {
        _received = received;
        _total = total;
      });
    }

    try {
      final file = widget.paths == null
          ? await widget.client.downloadFile(
              widget.path,
              name: _name,
              onProgress: progress,
              cancel: _cancel,
            )
          : await widget.client.downloadArchive(
              widget.path,
              widget.paths!,
              name: _name,
              onProgress: progress,
              cancel: _cancel,
            );
      if (!mounted) {
        await file.dispose();
        return;
      }
      setState(() => _file = file);
    } on DownloadCancelled {
      // Closing the dialog has already cancelled the request.
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '下載失敗，請檢查連線後重試',
        );
      }
    }
  }

  Future<void> _export(
    FileExportAction action,
    BuildContext buttonContext,
  ) async {
    final box = buttonContext.findRenderObject() as RenderBox?;
    final origin = box != null
        ? box.localToGlobal(Offset.zero) & box.size
        : const Rect.fromLTWH(0, 0, 1, 1);
    // Invoke Web Share before awaiting anything so this click remains a user gesture.
    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      final operation = action == FileExportAction.share
          ? platform.shareDownload(_file!, origin)
          : platform.saveDownload(_file!);
      final exported = await operation;
      if (mounted && exported) Navigator.of(context).pop();
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is FormatException
              ? error.message
              : '無法儲存或分享檔案，請重試',
        );
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = widget.action;
    Widget exportButton(FileExportAction action, {bool filled = false}) =>
        Builder(
          builder: (buttonContext) {
            final text = action == FileExportAction.share ? '分享檔案' : '儲存檔案';
            final icon = action == FileExportAction.share
                ? Icons.ios_share_rounded
                : Icons.download_rounded;
            final onPressed = _exporting
                ? null
                : () => _export(action, buttonContext);
            return filled
                ? FilledButton.icon(
                    onPressed: onPressed,
                    icon: Icon(icon),
                    label: Text(text),
                  )
                : TextButton.icon(
                    onPressed: onPressed,
                    icon: Icon(icon),
                    label: Text(text),
                  );
          },
        );
    return PopScope(
      canPop: !_busy && !_exporting,
      child: AlertDialog(
        title: Text(
          _busy
              ? (widget.paths == null ? '下載檔案' : '打包並下載 ZIP')
              : _file == null
              ? '下載失敗'
              : '檔案已備妥',
        ),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_name, maxLines: 3, overflow: TextOverflow.ellipsis),
              if (widget.paths != null) Text('已選取 ${widget.paths!.length} 個項目'),
              const SizedBox(height: 16),
              if (_busy) ...[
                LinearProgressIndicator(
                  value: _total != null && _total! > 0
                      ? (_received / _total!).clamp(0, 1)
                      : null,
                ),
                const SizedBox(height: 8),
                Text(
                  _total == null
                      ? '已下載 ${formatBytes(_received)}'
                      : '${(_total == 0 ? 100 : _received * 100 / _total!).toStringAsFixed(0)}% · ${formatBytes(_received)} / ${formatBytes(_total!)}',
                ),
              ],
              if (_file != null) Text(formatBytes(_file!.size)),
              if (_exporting)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _exporting
                ? null
                : () {
                    _cancel.cancel();
                    Navigator.of(context).pop();
                  },
            child: Text(_busy ? '取消下載' : '關閉'),
          ),
          if (_file != null) ...[
            exportButton(
              primary == FileExportAction.save
                  ? FileExportAction.share
                  : FileExportAction.save,
            ),
            exportButton(primary, filled: true),
          ],
        ],
      ),
    );
  }
}
