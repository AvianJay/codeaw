import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../app_state.dart';
import '../../data/remote_desktop_controller.dart';

class RemoteDesktopPage extends StatefulWidget {
  const RemoteDesktopPage({super.key});
  @override
  State<RemoteDesktopPage> createState() => _RemoteDesktopPageState();
}

class _RemoteDesktopPageState extends State<RemoteDesktopPage> {
  RemoteDesktopController? _controller;
  late AppLifecycleListener _lifecycle;
  bool _keyboard = false, _trackpad = true;
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
          unawaited(_controller?.disconnect());
        } else {
          _controller?.release();
          _sentKeys.clear();
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

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('遠端桌面'),
        actions: [
          IconButton(
            tooltip: '刷新畫面',
            icon: const Icon(Icons.refresh_rounded),
            onPressed: c?.refresh,
          ),
          IconButton(
            tooltip: '觸控板／直接觸控',
            icon: Icon(_trackpad ? Icons.touch_app_outlined : Icons.ads_click),
            onPressed: () {
              c?.release();
              setState(() => _trackpad = !_trackpad);
            },
          ),
          IconButton(
            tooltip: '鍵盤',
            icon: Icon(_keyboard ? Icons.keyboard_hide : Icons.keyboard),
            onPressed: () {
              c?.release();
              setState(() => _keyboard = !_keyboard);
              if (!_keyboard) _focus.requestFocus();
            },
          ),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      children: [
                        DropdownButton<DesktopMode>(
                          value: c.mode,
                          underline: const SizedBox.shrink(),
                          items: [
                            for (final mode in DesktopMode.values)
                              DropdownMenuItem(
                                value: mode,
                                child: Text(mode.label),
                              ),
                          ],
                          onChanged: (mode) {
                            if (mode != null) {
                              unawaited(c.configure(mode: mode));
                            }
                          },
                        ),
                        const SizedBox(width: 16),
                        if (c.mode == DesktopMode.smooth) ...[
                          DropdownButton<int>(
                            value: c.requestedFps,
                            underline: const SizedBox.shrink(),
                            items: [
                              const DropdownMenuItem(
                                value: 30,
                                child: Text('30 fps'),
                              ),
                              DropdownMenuItem(
                                value: 60,
                                enabled: c.hardware,
                                child: const Text('60 fps'),
                              ),
                            ],
                            onChanged: (fps) {
                              if (fps != null) unawaited(c.configure(fps: fps));
                            },
                          ),
                          const SizedBox(width: 16),
                        ],
                        if (c.monitors.isNotEmpty) ...[
                          DropdownButton<String>(
                            value: c.monitors.any((m) => m['id'] == c.monitorId)
                                ? c.monitorId
                                : null,
                            hint: const Text('螢幕'),
                            underline: const SizedBox.shrink(),
                            items: [
                              for (var i = 0; i < c.monitors.length; i++)
                                DropdownMenuItem(
                                  value: c.monitors[i]['id'] as String,
                                  child: Text('螢幕 ${i + 1}'),
                                ),
                            ],
                            onChanged: (id) {
                              if (id != null) {
                                unawaited(c.configure(monitorId: id));
                              }
                            },
                          ),
                          const SizedBox(width: 16),
                        ],
                        DropdownButton<String>(
                          value: c.privilege,
                          underline: const SizedBox.shrink(),
                          items: [
                            const DropdownMenuItem(
                              value: 'user',
                              child: Text('一般權限'),
                            ),
                            DropdownMenuItem(
                              value: 'system',
                              enabled: c.systemAvailable,
                              child: const Text('進階權限'),
                            ),
                          ],
                          onChanged: (privilege) {
                            if (privilege != null) {
                              unawaited(c.configure(privilege: privilege));
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                if (c.notice != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    child: Text(
                      c.notice!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                Expanded(
                  child: Focus(
                    focusNode: _focus,
                    onKeyEvent: _key,
                    onFocusChange: (focused) {
                      if (!focused) {
                        c.release();
                        _sentKeys.clear();
                      }
                    },
                    child: c.width > 0 && (c.image != null || c.video != null)
                        ? _DesktopCanvas(
                            controller: c,
                            trackpad: _trackpad,
                            focus: _focus,
                          )
                        : Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (c.loading || c.state == 'connecting')
                                    const CircularProgressIndicator(),
                                  const SizedBox(height: 16),
                                  Text(
                                    c.error ?? c.notice ?? '正在取得桌面畫面…',
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton.icon(
                                    onPressed: c.loading
                                        ? null
                                        : () {
                                            unawaited(c.connect());
                                          },
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('重新連線'),
                                  ),
                                  if (!c.systemAvailable)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 16),
                                      child: Text(
                                        '登入、解鎖及 UAC 操作需要在電腦端啟用進階桌面服務。',
                                        textAlign: TextAlign.center,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                  ),
                ),
                if (c.width > 0 && !c.active)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(c.error ?? c.notice ?? '等待桌面更新，輸入已暫停'),
                  ),
                if (_keyboard)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: TextField(
                      controller: _text,
                      autofocus: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      decoration: const InputDecoration(
                        hintText: '輸入文字（中文組字完成後送出）',
                        border: OutlineInputBorder(),
                      ),
                      onSubmitted: (_) => _shortcut([13]),
                    ),
                  ),
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
                          onPressed: c.canInput
                              ? () => c.input({'kind': 'sas'})
                              : null,
                          child: const Text('Ctrl+Alt+Del'),
                        ),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                    child: Row(
                      children: [
                        Icon(
                          c.active ? Icons.circle : Icons.pause_circle_outline,
                          size: 10,
                          color: c.active ? Colors.green : Colors.orange,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${c.actualMode.label} · ${c.fps.toStringAsFixed(0)} fps · ${(c.bytesReceived / 1048576).toStringAsFixed(2)} MiB',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const Spacer(),
                        if (c.updatedAt != null)
                          Text(
                            '${c.updatedAt!.hour.toString().padLeft(2, '0')}:${c.updatedAt!.minute.toString().padLeft(2, '0')}:${c.updatedAt!.second.toString().padLeft(2, '0')}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _DesktopCanvas extends StatefulWidget {
  const _DesktopCanvas({
    required this.controller,
    required this.trackpad,
    required this.focus,
  });
  final RemoteDesktopController controller;
  final bool trackpad;
  final FocusNode focus;
  @override
  State<_DesktopCanvas> createState() => _DesktopCanvasState();
}

class _DesktopCanvasState extends State<_DesktopCanvas> {
  final _transform = TransformationController();
  final _surface = GlobalKey();
  Size _viewport = Size.zero, _image = Size.zero;
  final _pointers = <int>{};
  Offset _down = Offset.zero;
  bool _dragging = false;
  Timer? _hold, _moveTimer;
  Offset? _move;
  RemoteDesktopController get c => widget.controller;
  Offset _point(Offset global) {
    final box = _surface.currentContext?.findRenderObject() as RenderBox?;
    final p = box?.globalToLocal(global) ?? Offset.zero;
    return Offset((p.dx / c.width).clamp(0, 1), (p.dy / c.height).clamp(0, 1));
  }

  void _pointer(Offset p) {
    _move = p;
    _moveTimer ??= Timer(const Duration(milliseconds: 34), () {
      _moveTimer = null;
      final target = _move;
      if (target != null) {
        c.input({'kind': 'pointer', 'x': target.dx, 'y': target.dy});
      }
    });
  }

  void _button(String button, bool down, Offset point) {
    _moveTimer?.cancel();
    _moveTimer = null;
    _move = null;
    c.input({
      'kind': 'button',
      'button': button,
      'down': down,
      'x': point.dx,
      'y': point.dy,
    });
  }

  void _start(PointerDownEvent event) {
    widget.focus.requestFocus();
    _pointers.add(event.pointer);
    _down = event.position;
    if (_pointers.length > 1) {
      _hold?.cancel();
      c.release();
      _dragging = false;
      return;
    }
    if (event.kind == ui.PointerDeviceKind.mouse || !widget.trackpad) {
      _button(
        event.buttons & kSecondaryMouseButton != 0
            ? 'right'
            : event.buttons & kMiddleMouseButton != 0
            ? 'middle'
            : 'left',
        true,
        _point(event.position),
      );
    } else {
      _hold = Timer(const Duration(milliseconds: 400), () {
        if (_pointers.length == 1) {
          _dragging = true;
          _button(
            'left',
            true,
            Offset(c.cursorX.clamp(0, 1), c.cursorY.clamp(0, 1)),
          );
        }
      });
    }
  }

  void _update(PointerMoveEvent event) {
    if (_pointers.length > 1) return;
    if (widget.trackpad && event.kind != ui.PointerDeviceKind.mouse) {
      final scale = _transform.value.getMaxScaleOnAxis();
      final p = Offset(
        (c.cursorX + event.delta.dx / (c.width * scale)).clamp(0, 1),
        (c.cursorY + event.delta.dy / (c.height * scale)).clamp(0, 1),
      );
      c.cursorX = p.dx;
      c.cursorY = p.dy;
      _pointer(p);
      setState(() {});
      if ((event.position - _down).distance > 6 && !_dragging) _hold?.cancel();
    } else {
      _pointer(_point(event.position));
    }
  }

  void _end(PointerUpEvent event) {
    _hold?.cancel();
    final wasSingle = _pointers.length == 1;
    _pointers.remove(event.pointer);
    if (!wasSingle) {
      c.release();
      return;
    }
    if (widget.trackpad && event.kind != ui.PointerDeviceKind.mouse) {
      final point = Offset(c.cursorX.clamp(0, 1), c.cursorY.clamp(0, 1));
      if (_dragging) {
        _button('left', false, point);
        _dragging = false;
      } else if ((event.position - _down).distance < 6) {
        _button('left', true, point);
        _button('left', false, point);
      }
    } else {
      c.release();
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _moveTimer?.cancel();
    c.release();
    _transform.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final viewport = Size(constraints.maxWidth, constraints.maxHeight),
          image = Size(c.width, c.height);
      if (viewport != _viewport || image != _image) {
        _viewport = viewport;
        _image = image;
        final scale =
            (viewport.width / image.width) < (viewport.height / image.height)
            ? viewport.width / image.width
            : viewport.height / image.height;
        _transform.value = Matrix4.diagonal3Values(scale, scale, 1)
          ..setTranslationRaw(
            (viewport.width - image.width * scale) / 2,
            (viewport.height - image.height * scale) / 2,
            0,
          );
      }
      return ColoredBox(
        color: Colors.black,
        child: InteractiveViewer(
          transformationController: _transform,
          constrained: false,
          minScale: .05,
          maxScale: 6,
          panEnabled: !widget.trackpad,
          scaleEnabled: true,
          boundaryMargin: const EdgeInsets.all(200),
          child: Listener(
            onPointerDown: _start,
            onPointerMove: _update,
            onPointerUp: _end,
            onPointerCancel: (event) {
              _pointers.remove(event.pointer);
              _hold?.cancel();
              c.release();
            },
            onPointerHover: (event) => _pointer(_point(event.position)),
            onPointerSignal: (event) {
              if (event is PointerScrollEvent) {
                final point = _point(event.position);
                c.input({
                  'kind': 'wheel',
                  'delta': (-event.scrollDelta.dy * 3).round().clamp(
                    -1200,
                    1200,
                  ),
                  'x': point.dx,
                  'y': point.dy,
                });
              }
            },
            child: SizedBox(
              key: _surface,
              width: c.width,
              height: c.height,
              child: Stack(
                children: [
                  Positioned.fill(
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
                  if (c.cursorVisible &&
                      c.cursorX >= 0 &&
                      c.cursorX <= 1 &&
                      c.cursorY >= 0 &&
                      c.cursorY <= 1)
                    Positioned(
                      left: c.cursorX * c.width - c.cursorHotX,
                      top: c.cursorY * c.height - c.cursorHotY,
                      child: IgnorePointer(
                        child: c.cursorPng != null
                            ? Image.memory(
                                c.cursorPng!,
                                width: c.cursorWidth,
                                height: c.cursorHeight,
                                gaplessPlayback: true,
                              )
                            : const Icon(
                                Icons.navigation,
                                size: 20,
                                color: Colors.white,
                                shadows: [
                                  Shadow(color: Colors.black, blurRadius: 3),
                                ],
                              ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
