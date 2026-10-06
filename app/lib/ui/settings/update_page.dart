import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';
import '../../data/app_updater.dart';
import '../common/adaptive.dart';

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  @override
  void initState() {
    super.initState();
    unawaited(AppScope.read(context).updater.initialize());
  }

  @override
  Widget build(BuildContext context) {
    final updater = AppScope.read(context).updater;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('App 更新')),
      body: ListenableBuilder(
        listenable: updater,
        builder: (context, _) => ContentScrollFrame(
          maxWidth: 640,
          builder: (context, padding) => ListView(
            padding: padding,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.system_update_rounded),
                title: Text('目前版本 ${updater.installedVersion}'),
                subtitle: Text('安裝版本的頻道：${updater.buildChannel.name}'),
              ),
              const SizedBox(height: 16),
              Text('更新頻道', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              SegmentedButton<UpdateChannel>(
                segments: const [
                  ButtonSegment(
                    value: UpdateChannel.release,
                    label: Text('release'),
                  ),
                  ButtonSegment(
                    value: UpdateChannel.nightly,
                    label: Text('nightly'),
                  ),
                ],
                selected: {updater.channel},
                onSelectionChanged: updater.busy
                    ? null
                    : (value) => updater.setChannel(value.single),
              ),
              const SizedBox(height: 8),
              const Text('release：正式版本。nightly：最新開發版本，可能較不穩定。'),
              const SizedBox(height: 24),
              if (!updater.supported) ...[
                const Text('網頁版隨 bridge 更新。手機安裝包可以從發佈頁下載。'),
                const SizedBox(height: 12),
              ] else ...[
                OutlinedButton.icon(
                  onPressed: updater.busy && updater.installed != null
                      ? null
                      : () => updater.check(),
                  icon: updater.checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded),
                  label: Text(updater.checking ? '檢查中…' : '檢查更新'),
                ),
                if (updater.release != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    updater.updateAvailable
                        ? '可安裝 ${updater.release!.displayVersion}'
                        : '已是此頻道的最新版本',
                    style: theme.textTheme.titleMedium,
                  ),
                  if (!updater.updateAvailable)
                    Text('頻道版本 ${updater.release!.displayVersion}'),
                  if (updater.asset == null)
                    const Text('此版本沒有提供這個平台的安裝包，請查看發佈頁。'),
                  if (updater.switchingChannel) ...[
                    const SizedBox(height: 8),
                    const Text(
                      '安裝後會切換到所選頻道。Android 不允許安裝較舊的版本；若系統拒絕，請等待該頻道發佈較新的版本。',
                    ),
                  ],
                  if (updater.platform == TargetPlatform.iOS &&
                      updater.asset != null) ...[
                    const SizedBox(height: 20),
                    DropdownButtonFormField<IosInstaller>(
                      initialValue: updater.iosInstaller,
                      decoration: const InputDecoration(
                        labelText: 'iOS 安裝方式',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final method in IosInstaller.values)
                          DropdownMenuItem(
                            value: method,
                            child: Text(method.label),
                          ),
                      ],
                      onChanged: updater.busy
                          ? null
                          : (value) {
                              if (value != null) updater.setIosInstaller(value);
                            },
                    ),
                    const SizedBox(height: 8),
                    const Text('IPA 需要由簽署／側載工具安裝。請先設定工具；無法開啟時會改用瀏覽器下載。'),
                    if (updater.iosInstaller == IosInstaller.custom) ...[
                      const SizedBox(height: 12),
                      TextFormField(
                        initialValue: updater.customIosInstaller,
                        autocorrect: false,
                        enableSuggestions: false,
                        keyboardType: TextInputType.url,
                        decoration: InputDecoration(
                          labelText: '自訂安裝連結',
                          hintText: 'mysigner://import?url={url}',
                          helperText: '貼上安裝工具的 URL Scheme，{url} 會代入 IPA 連結。',
                          helperMaxLines: 3,
                          errorText: updater.customIosInstallerError,
                          errorMaxLines: 3,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: updater.setCustomIosInstaller,
                      ),
                    ],
                    if (updater.iosInstaller == IosInstaller.lcSign)
                      const Text(
                        'LCSign 會下載並匯入 IPA；請在 LCSign 使用原本的憑證與 App 識別碼簽署安裝，以保留 App 資料。',
                      ),
                  ],
                  if (updater.updateAvailable && updater.asset != null) ...[
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed:
                          updater.busy ||
                              (updater.platform == TargetPlatform.iOS &&
                                  updater.iosInstaller == IosInstaller.custom &&
                                  updater.customIosInstallerError != null)
                          ? null
                          : updater.install,
                      icon: const Icon(Icons.download_rounded),
                      label: Text(
                        updater.installing
                            ? '處理中…'
                            : updater.platform == TargetPlatform.android
                            ? '下載並安裝 APK'
                            : '下載／安裝 IPA',
                      ),
                    ),
                  ],
                  if (updater.installing) ...[
                    const SizedBox(height: 12),
                    LinearProgressIndicator(value: updater.progress),
                    const SizedBox(height: 4),
                    Text(
                      updater.progress == null
                          ? '準備安裝…'
                          : '下載 APK ${(updater.progress! * 100).round()}%',
                    ),
                  ],
                ],
              ],
              if (updater.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  updater.error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
              if (updater.message != null) ...[
                const SizedBox(height: 12),
                Text(updater.message!),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton.icon(
                    onPressed: updater.installing
                        ? null
                        : () => updater.openDownload(releaseNotes: true),
                    icon: const Icon(Icons.open_in_new_rounded),
                    label: const Text('查看發佈頁'),
                  ),
                  if (updater.asset != null) ...[
                    TextButton.icon(
                      onPressed: updater.installing
                          ? null
                          : () => updater.openDownload(),
                      icon: const Icon(Icons.language_rounded),
                      label: const Text('瀏覽器下載'),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: updater.asset!.url.toString()),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已複製下載連結')),
                        );
                      },
                      icon: const Icon(Icons.copy_rounded),
                      label: const Text('複製下載連結'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
