import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../app_state.dart';
import '../../data/remote_desktop_controller.dart';
import '../common/adaptive.dart';
import 'desktop_trackpad_gestures.dart';
import 'remote_desktop_gesture_guide.dart';

class RemoteDesktopPage extends StatefulWidget {
  const RemoteDesktopPage({super.key});
  @override
  State<RemoteDesktopPage> createState() => _RemoteDesktopPageState();
}

class _RemoteDesktopPageState extends State<RemoteDesktopPage> {
  RemoteDesktopController? _controller;
  late AppLifecycleListener _lifecycle;
  bool _keyboard = false, _showingGuide = false;
  double _zoom = 1;
  final _canvas = GlobalKey<_DesktopCanvasState>();
  final _text = TextEditingController();
  final _focus = FocusNode();
  final _sentKeys = <PhysicalKeyboardKey, int>{};

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          if (_controller?.visible == false) unawaited(_controller?.connect());
        } else if (state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden ||
            state == AppLifecycleState.detached) {
          _releaseInput();
          unawaited(_controller?.disconnect());
        } else {
          _releaseInput();
        }
      },
    );
    _text.addListener(_commitText);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _controller = AppScope.read(context).desktop;
      _controller?.addListener(_changed);
      unawaited(_controller?.connect());
      _focus.requestFocus();
      setState(() {});
      unawaited(_firstUseGuide());
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _commitText() {
    final value = _text.value;
    if (value.text.isEmpty ||
        (value.composing.isValid && !value.composing.isCollapsed)) {
      return;
    }
    if (_controller?.canInput == true) {
      _controller!.input({'kind': 'text', 'text': value.text});
    }
    _text.clear();
  }

  int? _virtualKey(LogicalKeyboardKey key) {
    final keys = {
      LogicalKeyboardKey.controlLeft: 0xA2,
      LogicalKeyboardKey.controlRight: 0xA3,
      LogicalKeyboardKey.shiftLeft: 0xA0,
      LogicalKeyboardKey.shiftRight: 0xA1,
      LogicalKeyboardKey.altLeft: 0xA4,
      LogicalKeyboardKey.altRight: 0xA5,
      LogicalKeyboardKey.metaLeft: 0x5B,
      LogicalKeyboardKey.metaRight: 0x5C,
      LogicalKeyboardKey.enter: 13,
      LogicalKeyboardKey.numpadEnter: 13,
      LogicalKeyboardKey.escape: 27,
      LogicalKeyboardKey.tab: 9,
      LogicalKeyboardKey.backspace: 8,
      LogicalKeyboardKey.delete: 46,
      LogicalKeyboardKey.insert: 45,
      LogicalKeyboardKey.home: 36,
      LogicalKeyboardKey.end: 35,
      LogicalKeyboardKey.pageUp: 33,
      LogicalKeyboardKey.pageDown: 34,
      LogicalKeyboardKey.arrowLeft: 37,
      LogicalKeyboardKey.arrowUp: 38,
      LogicalKeyboardKey.arrowRight: 39,
      LogicalKeyboardKey.arrowDown: 40,
      LogicalKeyboardKey.space: 32,
    };
    if (keys.containsKey(key)) return keys[key];
    if (key.keyLabel.length == 1) {
      final code = key.keyLabel.toUpperCase().codeUnitAt(0);
      if ((code >= 65 && code <= 90) || (code >= 48 && code <= 57)) return code;
    }
    final functions = [
      LogicalKeyboardKey.f1,
      LogicalKeyboardKey.f2,
      LogicalKeyboardKey.f3,
      LogicalKeyboardKey.f4,
      LogicalKeyboardKey.f5,
      LogicalKeyboardKey.f6,
      LogicalKeyboardKey.f7,
      LogicalKeyboardKey.f8,
      LogicalKeyboardKey.f9,
      LogicalKeyboardKey.f10,
      LogicalKeyboardKey.f11,
      LogicalKeyboardKey.f12,
    ];
    final index = functions.indexOf(key);
    return index < 0 ? null : 112 + index;
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    final c = _controller;
    if (c?.canInput != true || _keyboard) return KeyEventResult.ignored;
    if (event is KeyUpEvent) {
      final code = _sentKeys.remove(event.physicalKey);
      if (code != null) c!.input({'kind': 'key', 'code': code, 'down': false});
      return KeyEventResult.handled;
    }
    final shortcut =
        HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (!shortcut &&
        event.character != null &&
        event.character!.isNotEmpty &&
        event.character!.codeUnitAt(0) >= 32) {
      c!.input({'kind': 'text', 'text': event.character});
      return KeyEventResult.handled;
    }
    final code = _virtualKey(event.logicalKey);
    if (code == null) return KeyEventResult.ignored;
    _sentKeys[event.physicalKey] = code;
    c!.input({'kind': 'key', 'code': code, 'down': true});
    return KeyEventResult.handled;
  }

  void _shortcut(List<int> codes) {
    final c = _controller;
    if (c?.canInput != true) return;
    for (final code in codes) {
      c!.input({'kind': 'key', 'code': code, 'down': true});
    }
    for (final code in codes.reversed) {
      c!.input({'kind': 'key', 'code': code, 'down': false});
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller?.removeListener(_changed);
    unawaited(_controller?.disconnect());
    _text.removeListener(_commitText);
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _firstUseGuide() async {
    final preferences = await SharedPreferences.getInstance();
    if (!mounted ||
        preferences.getBool('desktop.gestureGuideSeen.v1') == true) {
      return;
    }
    await _showGuide();
    await preferences.setBool('desktop.gestureGuideSeen.v1', true);
  }

  void _releaseInput() {
    _canvas.currentState?.cancelInput();
    _controller?.release();
    _sentKeys.clear();
  }

  Future<void> _showGuide() async {
    if (_showingGuide || !mounted) return;
    _showingGuide = true;
    _releaseInput();
    await showAdaptiveSheet<void>(
      context: context,
      builder: (_) => const RemoteDesktopGestureGuide(),
    );
    _showingGuide = false;
    if (mounted && !_keyboard) _focus.requestFocus();
  }

  Future<void> _chooseMonitor() async {
    final c = _controller;
    if (c == null) return;
    _releaseInput();
    final id = await showAdaptiveSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '選擇螢幕',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (var i = 0; i < c.monitors.length; i++)
                ListTile(
                  leading: const Icon(Icons.desktop_windows_outlined),
                  title: Text('螢幕 ${i + 1}'),
                  subtitle: Text(
                    c.monitors[i]['primary'] == true ? '主要螢幕' : '延伸螢幕',
                  ),
                  trailing: c.monitors[i]['id'] == c.monitorId
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(context, c.monitors[i]['id']),
                ),
            ],
          ),
        ),
      ),
    );
    if (id != null && mounted) {
      setState(() => _zoom = 1);
      await c.configure(monitorId: id);
    }
  }

  Future<void> _chooseZoom() async {
    _releaseInput();
    final zoom = await showAdaptiveSheet<double>(
      context: context,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '畫面大小',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              for (final value in [1.0, 1.5, 2.0])
                ListTile(
                  leading: Icon(
                    value == 1
                        ? Icons.fit_screen_rounded
                        : Icons.zoom_in_rounded,
                  ),
                  title: Text(
                    value == 1 ? '符合視窗' : '${(value * 100).round()}%',
                  ),
                  subtitle: value == 1 ? null : const Text('畫面跟隨游標移動'),
                  trailing: _zoom == value
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.pop(context, value),
                ),
            ],
          ),
        ),
      ),
    );
    if (zoom != null && mounted) setState(() => _zoom = zoom);
  }

  Future<void> _connectionInfo() async {
    final c = _controller;
    if (c == null) return;
    _releaseInput();
    await showAdaptiveSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('連線資訊', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              const Text('畫質、幀率與權限會自動調整；已啟用省流量時會優先節省流量。'),
              const SizedBox(height: 16),
              for (final entry in {
                '畫質': c.actualMode.label,
                '幀率': '${c.fps.toStringAsFixed(0)} fps',
                '已接收': '${(c.bytesReceived / 1048576).toStringAsFixed(2)} MiB',
                '控制權限': c.privilege == 'system' ? '進階' : '一般',
              }.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Text(
                        entry.key,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const Spacer(),
                      Text(
                        entry.value,
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menu(String value) async {
    final c = _controller;
    switch (value) {
      case 'keyboard':
        _releaseInput();
        setState(() => _keyboard = !_keyboard);
        if (!_keyboard) _focus.requestFocus();
      case 'guide':
        await _showGuide();
      case 'monitor':
        await _chooseMonitor();
      case 'zoom':
        await _chooseZoom();
      case 'refresh':
        c?.refresh();
      case 'reconnect':
        _releaseInput();
        await c?.disconnect();
        await c?.connect();
      case 'info':
        await _connectionInfo();
    }
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    bool enabled = true,
  }) => PopupMenuItem(
    value: value,
    enabled: enabled,
    child: Row(
      children: [Icon(icon, size: 20), const SizedBox(width: 12), Text(label)],
    ),
  );

  Widget _keyboardPanel(RemoteDesktopController c) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final shortcut in <String, List<int>>{
                'Esc': [27],
                'Tab': [9],
                'Ctrl+C': [17, 67],
                'Ctrl+V': [17, 86],
                'Alt+Tab': [18, 9],
                'Win': [91],
                '⌫': [8],
                '←': [37],
                '↑': [38],
                '↓': [40],
                '→': [39],
              }.entries)
                TextButton(
                  onPressed: c.canInput
                      ? () => _shortcut(shortcut.value)
                      : null,
                  child: Text(shortcut.key),
                ),
              if (c.privilege == 'system')
                TextButton(
                  onPressed: c.canInput ? () => c.input({'kind': 'sas'}) : null,
                  child: const Text('Ctrl+Alt+Del'),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: TextField(
            controller: _text,
            autofocus: true,
            autocorrect: false,
            enableSuggestions: false,
            enableIMEPersonalizedLearning: false,
            decoration: InputDecoration(
              hintText: '輸入文字',
              helperText: '中文組字完成後送出',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: '收起鍵盤',
                icon: const Icon(Icons.keyboard_hide_rounded),
                onPressed: () => unawaited(_menu('keyboard')),
              ),
            ),
            onSubmitted: (_) => _shortcut([13]),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('遠端桌面'),
            if (c != null)
              Text(
                c.host.name + (c.active ? ' · 已連線' : ' · 連線中'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            tooltip: '桌面選項',
            icon: const Icon(Icons.more_vert_rounded),
            onOpened: _releaseInput,
            onSelected: (value) => unawaited(_menu(value)),
            itemBuilder: (_) => [
              _menuItem(
                'keyboard',
                _keyboard
                    ? Icons.keyboard_hide_rounded
                    : Icons.keyboard_outlined,
                _keyboard ? '收起鍵盤' : '顯示鍵盤',
                enabled: c != null,
              ),
              _menuItem('guide', Icons.touch_app_outlined, '手勢教學'),
              const PopupMenuDivider(),
              if (c != null && c.monitors.length > 1)
                _menuItem('monitor', Icons.desktop_windows_outlined, '選擇螢幕'),
              _menuItem(
                'zoom',
                Icons.fit_screen_rounded,
                '畫面大小',
                enabled: c != null && c.width > 0,
              ),
              _menuItem(
                'refresh',
                Icons.refresh_rounded,
                '刷新畫面',
                enabled: c != null,
              ),
              _menuItem(
                'reconnect',
                Icons.sync_rounded,
                '重新連線',
                enabled: c != null && !c.loading,
              ),
              _menuItem(
                'info',
                Icons.info_outline_rounded,
                '連線資訊',
                enabled: c != null,
              ),
            ],
          ),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: Column(
                children: [
                  Expanded(
                    child: Focus(
                      focusNode: _focus,
                      onKeyEvent: _key,
                      onFocusChange: (focused) {
                        if (!focused) _releaseInput();
                      },
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (c.width > 0 &&
                              (c.image != null || c.video != null))
                            _DesktopCanvas(
                              key: _canvas,
                              controller: c,
                              focus: _focus,
                              zoom: _zoom,
                            )
                          else
                            Center(
                              child: SingleChildScrollView(
                                padding: const EdgeInsets.all(28),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (c.loading || c.state == 'connecting')
                                      const CircularProgressIndicator()
                                    else
                                      Icon(
                                        Icons.desktop_access_disabled_outlined,
                                        size: 48,
                                        color: colors.onSurfaceVariant,
                                      ),
                                    const SizedBox(height: 20),
                                    Text(
                                      c.error ?? c.notice ?? '正在取得桌面畫面…',
                                      textAlign: TextAlign.center,
                                    ),
                                    const SizedBox(height: 20),
                                    FilledButton.tonalIcon(
                                      onPressed: c.loading
                                          ? null
                                          : () => unawaited(_menu('reconnect')),
                                      icon: const Icon(Icons.refresh_rounded),
                                      label: const Text('重新連線'),
                                    ),
                                    const SizedBox(height: 12),
                                    TextButton.icon(
                                      onPressed: () => unawaited(_showGuide()),
                                      icon: const Icon(
                                        Icons.touch_app_outlined,
                                        size: 18,
                                      ),
                                      label: const Text('查看手勢教學'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          if (c.width > 0 && (!c.active || c.notice != null))
                            Positioned(
                              left: 16,
                              right: 16,
                              top: 12,
                              child: IgnorePointer(
                                child: Material(
                                  color: colors.surfaceContainerHigh.withValues(
                                    alpha: .94,
                                  ),
                                  borderRadius: BorderRadius.circular(12),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 10,
                                    ),
                                    child: Text(
                                      c.error ?? c.notice ?? '等待桌面更新…',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                      textAlign: TextAlign.center,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  if (_keyboard) _keyboardPanel(c),
                ],
              ),
            ),
    );
  }
}

class _DesktopCanvas extends StatefulWidget {
  const _DesktopCanvas({
    super.key,
    required this.controller,
    required this.focus,
    required this.zoom,
  });
  final RemoteDesktopController controller;
  final FocusNode focus;
  final double zoom;
  @override
  State<_DesktopCanvas> createState() => _DesktopCanvasState();
}

class _DesktopCanvasState extends State<_DesktopCanvas> {
  late final DesktopTrackpadGestures _gestures;
  final _surface = GlobalKey();
  Rect _imageRect = Rect.zero;
  Offset _cursor = const Offset(.5, .5);
  Offset _panAnchor = const Offset(.5, .5);
  int _cursorRevision = -1;
  bool _mouseActive = false;
  final _mouseButtons = <String>{};
  Timer? _mouseMoveTimer;
  Offset? _mouseMove;
  bool _syncing = false;

  RemoteDesktopController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _gestures = DesktopTrackpadGestures(
      send: (input) => c.input(input),
      onCursorChanged: (cursor) {
        _cursor = cursor;
        if (!_mouseActive) _panAnchor = cursor;
        if (mounted && !_syncing) setState(() {});
      },
    );
    _syncRemoteCursor();
  }

  void _syncRemoteCursor() {
    if (_cursorRevision == c.cursorRevision) return;
    _cursorRevision = c.cursorRevision;
    _syncing = true;
    _gestures.syncRemoteCursor(Offset(c.cursorX, c.cursorY));
    _cursor = _gestures.cursor;
    _syncing = false;
  }

  @override
  void didUpdateWidget(covariant _DesktopCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!c.canInput) cancelInput();
    if (oldWidget.zoom != widget.zoom) _panAnchor = _cursor;
    _syncRemoteCursor();
  }

  Offset _point(Offset global) {
    final box = _surface.currentContext?.findRenderObject() as RenderBox?;
    final local = box?.globalToLocal(global) ?? Offset.zero;
    return Offset(
      ((local.dx - _imageRect.left) / _imageRect.width).clamp(0, 1),
      ((local.dy - _imageRect.top) / _imageRect.height).clamp(0, 1),
    );
  }

  void _flushMouseMove() {
    _mouseMoveTimer?.cancel();
    _mouseMoveTimer = null;
    final point = _mouseMove;
    _mouseMove = null;
    if (point != null) {
      c.input({'kind': 'pointer', 'x': point.dx, 'y': point.dy});
    }
  }

  void _moveMouse(Offset global) {
    if (!c.canInput || _gestures.hasContacts) return;
    _mouseActive = true;
    _cursor = _point(global);
    _mouseMove = _cursor;
    _mouseMoveTimer ??= Timer(
      const Duration(milliseconds: 16),
      _flushMouseMove,
    );
    setState(() {});
  }

  void _down(PointerDownEvent event) {
    widget.focus.requestFocus();
    if (!c.canInput) return;
    if (event.kind != ui.PointerDeviceKind.mouse) {
      if (!_gestures.hasContacts) {
        _flushMouseMove();
        if (_mouseButtons.isNotEmpty) {
          _mouseButtons.clear();
          c.release();
        }
        _gestures.adoptLocalCursor(_cursor);
      }
      _mouseActive = false;
      _gestures.pointerDown(event.pointer, event.position);
      return;
    }
    if (_gestures.hasContacts) _gestures.cancel();
    _flushMouseMove();
    _mouseActive = true;
    final point = _point(event.position);
    _cursor = point;
    final button = event.buttons & kSecondaryMouseButton != 0
        ? 'right'
        : event.buttons & kMiddleMouseButton != 0
        ? 'middle'
        : 'left';
    _mouseButtons.add(button);
    c.input({
      'kind': 'button',
      'button': button,
      'down': true,
      'x': point.dx,
      'y': point.dy,
    });
    setState(() {});
  }

  void _move(PointerMoveEvent event) {
    if (!c.canInput) {
      cancelInput();
      return;
    }
    if (event.kind == ui.PointerDeviceKind.mouse) {
      _moveMouse(event.position);
    } else {
      _gestures.pointerMove(event.pointer, event.position);
    }
  }

  void _up(PointerUpEvent event) {
    if (event.kind != ui.PointerDeviceKind.mouse) {
      _gestures.pointerUp(event.pointer);
      return;
    }
    _flushMouseMove();
    final point = _point(event.position);
    for (final button in _mouseButtons) {
      c.input({
        'kind': 'button',
        'button': button,
        'down': false,
        'x': point.dx,
        'y': point.dy,
      });
    }
    _mouseButtons.clear();
  }

  void cancelInput() {
    _mouseMoveTimer?.cancel();
    _mouseMoveTimer = null;
    _mouseMove = null;
    _mouseButtons.clear();
    _gestures.cancel();
  }

  @override
  void dispose() {
    _mouseMoveTimer?.cancel();
    _gestures.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = constraints.biggest;
      final fitted = applyBoxFit(
        BoxFit.contain,
        Size(c.width, c.height),
        viewport,
      ).destination;
      final size = fitted * widget.zoom;
      _gestures.setViewport(
        Size(
          size.width.clamp(0, viewport.width),
          size.height.clamp(0, viewport.height),
        ),
      );
      double origin(double viewport, double image, double cursor) =>
          image <= viewport
          ? (viewport - image) / 2
          : (viewport - image) * cursor.clamp(0, 1);
      _imageRect = Rect.fromLTWH(
        origin(viewport.width, size.width, _panAnchor.dx),
        origin(viewport.height, size.height, _panAnchor.dy),
        size.width,
        size.height,
      );
      final cursorScale = (size.width / c.width).clamp(.75, 2.0);
      final cursorWidth = c.cursorWidth * cursorScale;
      final cursorHeight = c.cursorHeight * cursorScale;
      return Listener(
        key: _surface,
        behavior: HitTestBehavior.opaque,
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: (event) => event.kind == ui.PointerDeviceKind.mouse
            ? cancelInput()
            : _gestures.pointerCancel(event.pointer),
        onPointerHover: (event) => _moveMouse(event.position),
        onPointerSignal: (event) {
          if (event is PointerScrollEvent && c.canInput) {
            final point = _point(event.position);
            c.input({
              'kind': 'wheel',
              'delta': (-event.scrollDelta.dy * 3).round().clamp(-1200, 1200),
              'deltaX': (event.scrollDelta.dx * 3).round().clamp(-1200, 1200),
              'x': point.dx,
              'y': point.dy,
            });
          }
        },
        child: ClipRect(
          child: ColoredBox(
            color: const Color(0xff12161c),
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fromRect(
                  rect: _imageRect,
                  child: c.video != null && c.actualMode == DesktopMode.smooth
                      ? RTCVideoView(
                          c.video!,
                          objectFit: RTCVideoViewObjectFit
                              .RTCVideoViewObjectFitContain,
                        )
                      : RawImage(
                          image: c.image,
                          fit: BoxFit.fill,
                          filterQuality: FilterQuality.low,
                        ),
                ),
                if (c.cursorVisible)
                  Positioned(
                    left:
                        _imageRect.left +
                        _cursor.dx * size.width -
                        c.cursorHotX * cursorScale,
                    top:
                        _imageRect.top +
                        _cursor.dy * size.height -
                        c.cursorHotY * cursorScale,
                    child: IgnorePointer(
                      child: c.cursorPng != null
                          ? Image.memory(
                              c.cursorPng!,
                              width: cursorWidth,
                              height: cursorHeight,
                              gaplessPlayback: true,
                            )
                          : const Icon(
                              Icons.navigation_rounded,
                              size: 22,
                              color: Colors.white,
                              shadows: [
                                Shadow(color: Colors.black, blurRadius: 4),
                              ],
                            ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
