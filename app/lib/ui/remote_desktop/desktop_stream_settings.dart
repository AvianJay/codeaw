import 'package:flutter/material.dart';

import '../../data/remote_desktop_controller.dart';

@immutable
class DesktopStreamPreferences {
  const DesktopStreamPreferences({required this.mode, required this.fps});

  final DesktopMode? mode;
  final int? fps;
}

/// Edits a local draft. The caller applies the returned preferences after the
/// sheet closes; dismissing the sheet never changes the desktop connection.
class DesktopStreamSettings extends StatefulWidget {
  const DesktopStreamSettings({super.key, required this.controller});

  final RemoteDesktopController controller;

  @override
  State<DesktopStreamSettings> createState() => _DesktopStreamSettingsState();
}

class _DesktopStreamSettingsState extends State<DesktopStreamSettings> {
  late String _quality;
  late int _fps;

  RemoteDesktopController get c => widget.controller;
  DesktopMode? get _preferredMode => _quality == 'auto'
      ? null
      : DesktopMode.values.firstWhere((mode) => mode.name == _quality);

  DesktopMode get _effectiveMode {
    final selected =
        _preferredMode ??
        (c.dataSaver()
            ? DesktopMode.low
            : c.smoothAvailable
            ? DesktopMode.smooth
            : DesktopMode.balanced);
    return selected == DesktopMode.smooth && !c.smoothAvailable
        ? DesktopMode.balanced
        : selected;
  }

  int get _effectiveFps => switch (_effectiveMode) {
    DesktopMode.smooth => c.hardware ? (_fps == 0 ? 60 : _fps) : 30,
    DesktopMode.balanced => 15,
    DesktopMode.low => 2,
    DesktopMode.onDemand => 1,
  };

  String get _qualityDescription => switch (_preferredMode) {
    null => '依照省流量設定與電腦能力，自動選擇適合的畫質。',
    DesktopMode.balanced => '兼顧畫質與流量，最高 15 FPS。',
    DesktopMode.smooth => '動態畫面更流暢，會使用較多流量。',
    DesktopMode.low => '降低畫質與更新頻率，最高 2 FPS。',
    DesktopMode.onDemand => '優先節省流量，最高 1 FPS。',
  };

  String get _fpsDescription {
    if (_effectiveMode != DesktopMode.smooth) {
      return '${_effectiveMode.label}最高 $_effectiveFps FPS。'
          '切回高流暢後會沿用這裡的 FPS 設定。';
    }
    if (!c.hardware) {
      return _fps == 60
          ? '目前最高支援 30 FPS；會保留 60 FPS 選擇，支援時再使用。'
          : '這台電腦目前最高支援 30 FPS。';
    }
    return _fps == 0 ? '依電腦能力自動選擇，目前為 60 FPS。' : '較高 FPS 更流暢，也會增加流量與電腦負擔。';
  }

  @override
  void initState() {
    super.initState();
    _quality = c.preferredMode?.name ?? 'auto';
    _fps = c.preferredFps ?? 0;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      final supporting = theme.textTheme.bodySmall?.copyWith(
        color: colors.onSurfaceVariant,
        height: 1.5,
      );
      final mode = _effectiveMode;
      return SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '畫質與 FPS',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text('調整這台電腦的遠端桌面畫面。', style: supporting),
              const SizedBox(height: 24),
              DropdownButtonFormField<String>(
                initialValue: _quality,
                isExpanded: true,
                itemHeight: null,
                decoration: const InputDecoration(
                  labelText: '畫質',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: 'auto', child: Text('自動')),
                  for (final mode in DesktopMode.values)
                    DropdownMenuItem(value: mode.name, child: Text(mode.label)),
                ],
                onChanged: (quality) {
                  if (quality != null) setState(() => _quality = quality);
                },
              ),
              const SizedBox(height: 10),
              Text(_qualityDescription, style: supporting),
              const SizedBox(height: 24),
              Text(
                '幀率（FPS）',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  final vertical =
                      constraints.maxWidth < 260 ||
                      MediaQuery.textScalerOf(context).scale(14) > 18;
                  return SegmentedButton<int>(
                    direction: vertical ? Axis.vertical : Axis.horizontal,
                    expandedInsets: vertical ? null : EdgeInsets.zero,
                    showSelectedIcon: false,
                    segments: [
                      const ButtonSegment(value: 0, label: Text('自動')),
                      const ButtonSegment(value: 30, label: Text('30 FPS')),
                      ButtonSegment(
                        value: 60,
                        label: const Text('60 FPS'),
                        enabled: c.hardware,
                      ),
                    ],
                    selected: {_fps},
                    onSelectionChanged: mode == DesktopMode.smooth
                        ? (value) => setState(() => _fps = value.single)
                        : null,
                  );
                },
              ),
              const SizedBox(height: 10),
              Text(_fpsDescription, style: supporting),
              const SizedBox(height: 20),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '套用後：${mode.label} · 最高 $_effectiveFps FPS',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _preferredMode == null
                            ? c.dataSaver()
                                  ? '已開啟省流量，畫質會自動選擇低流量。'
                                  : '自動設定會跟隨全域省流量選項。'
                            : '手動選擇畫質會優先於全域省流量設定。',
                        style: supporting,
                      ),
                      if (_preferredMode == DesktopMode.smooth &&
                          !c.smoothAvailable) ...[
                        const SizedBox(height: 6),
                        Text('這台電腦目前無法使用高流暢，會先改用一般。', style: supporting),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              OverflowBar(
                spacing: 12,
                overflowSpacing: 8,
                alignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(
                      DesktopStreamPreferences(
                        mode: _preferredMode,
                        fps: _fps == 0 ? null : _fps,
                      ),
                    ),
                    child: const Text('套用'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
