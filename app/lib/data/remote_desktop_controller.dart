import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'host.dart';

enum DesktopMode {
  balanced('一般'),
  smooth('高流暢'),
  low('低流量'),
  onDemand('極省流量');

  const DesktopMode(this.label);
  final String label;
}

/// A desktop connection also works while ACP is unavailable at Windows sign-in.
class RemoteDesktopController extends ChangeNotifier {
  RemoteDesktopController(
    this.host,
    this.store, {
    required this.dataSaver,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();
  final HostConfig host;
  final HostStore store;
  final bool Function() dataSaver;
  DesktopMode mode = DesktopMode.balanced;
  DesktopMode actualMode = DesktopMode.balanced;
  DesktopMode? preferredMode;
  int? preferredFps;
  String privilege = 'user';
  int requestedFps = 30;
  int epoch = 0;
  String? monitorId;
  List<Map<String, dynamic>> monitors = [];
  bool systemAvailable = false, hardware = false, smoothAvailable = false;
  bool loading = false, active = false, visible = false, disposed = false;
  String? error, notice;
  String state = 'disconnected';
  ui.Image? image;
  RTCVideoRenderer? video;
  double width = 0, height = 0, cursorX = .5, cursorY = .5;

  /// Changes only for a newly accepted cursor message, not other UI updates.
  int cursorRevision = 0;
  bool cursorVisible = false;
  Uint8List? cursorPng;
  double cursorWidth = 20, cursorHeight = 20, cursorHotX = 0, cursorHotY = 0;
  int bytesReceived = 0;
  double fps = 0;
  DateTime? updatedAt;
  String? _url, _sessionId;
  WebSocketChannel? _socket;
  RTCPeerConnection? _peer;
  StreamSubscription<dynamic>? _subscription;
  Timer? _retry, _statsTimer;
  int _generation = 0, _lastSeq = 0, _attempt = 0, _videoBytes = 0, _frames = 0;
  Future<void>? _preferencesLoad;
  Future<void> _preferenceChanges = Future.value();
  Map<String, dynamic>? _sessionOptions;
  bool _socketAuthenticated = false;
  Future<void> _incoming = Future.value();
  final _candidates = <RTCIceCandidate>[];
  final http.Client _http;
  Map<String, String> get _headers => {
    'Authorization': 'Bearer ${host.token}',
    'Content-Type': 'application/json',
  };
  bool get canInput => active && !loading && _socket != null;
  bool get modeAutomatic => preferredMode == null;
  bool get fpsAutomatic => preferredFps == null;

  /// Includes the server's smooth-stream fallback while a session is active.
  int get targetFps => switch (active ? actualMode : mode) {
    DesktopMode.smooth => requestedFps,
    DesktopMode.balanced => 15,
    DesktopMode.low => 2,
    DesktopMode.onDemand => 1,
  };

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Map<String, dynamic>? data,
  ]) async {
    if (_url == null) throw StateError('電腦未連線');
    final uri = host.httpUri(_url!, path);
    final response = await switch (method) {
      'POST' => _http.post(uri, headers: _headers, body: jsonEncode(data)),
      'DELETE' => _http.delete(uri, headers: _headers),
      _ => _http.get(uri, headers: _headers),
    }.timeout(const Duration(seconds: 20));
    final result = response.bodyBytes.isEmpty
        ? <String, dynamic>{}
        : jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode >= 400) {
      if (response.statusCode == 401) visible = false;
      throw StateError(
        response.statusCode == 404
            ? '請更新電腦端 bridge 以使用遠端桌面'
            : result['error'] as String? ?? '桌面連線失敗',
      );
    }
    return result;
  }

  Future<void> _preferences() => _preferencesLoad ??= _loadPreferences();

  Future<void> _loadPreferences() async {
    final prefs = await store.loadDesktopPreferences(host);
    monitorId = prefs?['monitorId'] as String?;
    preferredMode = DesktopMode.values
        .where((mode) => mode.name == prefs?['preferredMode'])
        .firstOrNull;
    final fps = prefs?['preferredFps'];
    preferredFps = fps is int && (fps == 30 || fps == 60) ? fps : null;
  }

  void _selectOptions() {
    privilege = systemAvailable ? 'system' : 'user';
    final selectedMode =
        preferredMode ??
        (dataSaver()
            ? DesktopMode.low
            : smoothAvailable
            ? DesktopMode.smooth
            : DesktopMode.balanced);
    mode = selectedMode == DesktopMode.smooth && !smoothAvailable
        ? DesktopMode.balanced
        : selectedMode;
    requestedFps = mode == DesktopMode.smooth && hardware
        ? preferredFps ?? 60
        : 30;
  }

  Map<String, dynamic> get options => {
    'mode': mode.name,
    'privilege': privilege,
    'fps': requestedFps,
    'monitorId': ?monitorId,
  };
  Future<void> connect() async {
    visible = true;
    _retry?.cancel();
    if (loading || disposed) return;
    final generation = ++_generation;
    loading = true;
    active = false;
    error = null;
    state = 'connecting';
    _notify();
    try {
      await _preferences();
      _selectOptions();
      Map<String, dynamic>? info;
      for (final url in [_url, ...host.urls].whereType<String>().toSet()) {
        _url = url;
        try {
          info = await _request('GET', '/api/desktop/info');
          break;
        } catch (e) {
          if (!visible || url == host.urls.last) rethrow;
        }
      }
      if (generation != _generation || !visible || disposed) return;
      if (info == null) throw StateError('連不上電腦桌面');
      if (info['enabled'] != true) throw StateError('請在電腦端「設定」啟用遠端桌面');
      if (info['available'] != true) {
        throw StateError('請安裝支援遠端桌面的 Windows bridge');
      }
      systemAvailable = (info['privilegeModes'] as List? ?? []).contains(
        'system',
      );
      hardware = info['hardware'] == true;
      smoothAvailable = info['smooth'] == true;
      _selectOptions();
      monitors = (info['monitors'] as List? ?? [])
          .whereType<Map<String, dynamic>>()
          .toList();
      if (!monitors.any((m) => m['id'] == monitorId)) {
        monitorId =
            monitors.where((m) => m['primary'] == true).firstOrNull?['id']
                as String? ??
            monitors.firstOrNull?['id'] as String?;
      }
      final sessionOptions = options;
      final session = await _request(
        'POST',
        '/api/desktop/sessions',
        sessionOptions,
      );
      if (generation != _generation || !visible || disposed) {
        unawaited(
          _request(
            'DELETE',
            '/api/desktop/sessions/${session['sessionId']}',
          ).catchError((_) => <String, dynamic>{}),
        );
        return;
      }
      _sessionId = session['sessionId'] as String;
      _sessionOptions = sessionOptions;
      _socketAuthenticated = false;
      final base = HostConfig.httpBase(_url!);
      final socket = WebSocketChannel.connect(
        base.replace(
          scheme: base.scheme == 'https' ? 'wss' : 'ws',
          path: session['socketPath'] as String,
        ),
      );
      _socket = socket;
      _subscription = socket.stream.listen(
        (data) {
          _incoming = _incoming
              .then((_) async {
                if (generation != _generation || disposed) return;
                bytesReceived += data is String
                    ? utf8.encode(data).length
                    : (data as List).length;
                await receive(data, generation);
              })
              .catchError((_) {
                if (generation == _generation) {
                  error = '桌面畫面無法解碼，正在重新連線';
                  _lost(generation);
                }
              });
        },
        onDone: () => _lost(generation),
        onError: (Object _) => _lost(generation),
      );
      await socket.ready.timeout(const Duration(seconds: 8));
      if (generation != _generation) {
        await socket.sink.close();
        return;
      }
      socket.sink.add(
        jsonEncode({'type': 'auth', 'ticket': session['ticket']}),
      );
      _socketAuthenticated = true;
      _selectOptions();
      await _applyOptions();
      if (generation != _generation || disposed) return;
      _statsTimer?.cancel();
      _statsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        fps = _frames.toDouble();
        _frames = 0;
        unawaited(_videoStats());
        _notify();
      });
    } catch (e) {
      if (generation == _generation) {
        error = e is StateError
            ? e.message.toString()
            : '連不上桌面，請確認 Tailscale 與電腦端服務';
        state = 'disconnected';
        _queueRetry();
      }
    } finally {
      if (generation == _generation) {
        loading = false;
        _notify();
      }
    }
  }

  void _send(Map<String, dynamic> message) {
    if (disposed || _socket == null) return;
    try {
      _socket!.sink.add(jsonEncode(message));
    } catch (_) {
      /* Socket teardown releases input on the host. */
    }
  }

  void input(Map<String, dynamic> value) {
    if (canInput || value['kind'] == 'release') {
      _send({'type': 'input', 'epoch': epoch, 'input': value});
    }
  }

  void release() => input({'kind': 'release'});
  void refresh() => _send({'type': 'refresh'});

  Future<void> _serializePreferenceChange(Future<void> Function() change) {
    final pending = _preferenceChanges.then((_) async {
      if (disposed) return;
      await _preferences();
      if (!disposed) await change();
    });
    _preferenceChanges = pending.catchError((Object _) {});
    return pending;
  }

  Map<String, dynamic> _savedPreferences({
    required String? monitorId,
    required DesktopMode? mode,
    required int? fps,
  }) => {
    'monitorId': ?monitorId,
    'preferredMode': ?mode?.name,
    'preferredFps': ?fps,
  };

  /// Persists explicit stream choices; null restores automatic selection.
  /// Hidden or disconnected desktops apply these on their next connection.
  Future<void> setStreamPreferences({
    required DesktopMode? mode,
    required int? fps,
  }) {
    if (fps != null && fps != 30 && fps != 60) {
      return Future.error(ArgumentError.value(fps, 'fps', 'Expected 30 or 60'));
    }
    return _serializePreferenceChange(() async {
      if (preferredMode == mode && preferredFps == fps) return;
      await store.saveDesktopPreferences(
        host,
        _savedPreferences(monitorId: monitorId, mode: mode, fps: fps),
      );
      if (disposed) return;
      preferredMode = mode;
      preferredFps = fps;
      _selectOptions();
      await _applyOptions();
    });
  }

  /// Updates the monitor and reevaluates the selected connection settings.
  /// Legacy mode, fps and privilege arguments are accepted for compatibility;
  /// explicit stream choices use [setStreamPreferences].
  Future<void> configure({
    DesktopMode? mode,
    String? monitorId,
    int? fps,
    String? privilege,
  }) => _serializePreferenceChange(() async {
    final selectedMonitor = monitorId ?? this.monitorId;
    if (selectedMonitor != this.monitorId) {
      await store.saveDesktopPreferences(
        host,
        _savedPreferences(
          monitorId: selectedMonitor,
          mode: preferredMode,
          fps: preferredFps,
        ),
      );
      if (disposed) return;
      this.monitorId = selectedMonitor;
    }
    _selectOptions();
    await _applyOptions();
  });

  Future<void> _applyOptions() async {
    final selectedOptions = options;
    if (_socket == null ||
        !_socketAuthenticated ||
        mapEquals(_sessionOptions, selectedOptions)) {
      _notify();
      return;
    }
    if (_sessionOptions?['privilege'] != privilege) {
      await disconnect();
      await connect();
      return;
    }
    release();
    active = false;
    notice = null;
    _sessionOptions = selectedOptions;
    _send({'type': 'configure', 'options': selectedOptions});
    _notify();
  }

  Future<void> receive(dynamic data, int generation) async {
    if (generation != _generation || disposed) return;
    if (data is! String) {
      await _frame(Uint8List.fromList((data as List).cast<int>()), generation);
      return;
    }
    final msg = jsonDecode(data) as Map<String, dynamic>;
    if (msg['type'] != 'status' &&
        msg['epoch'] != null &&
        msg['epoch'] != epoch) {
      return;
    }
    switch (msg['type']) {
      case 'status':
        final nextEpoch = (msg['epoch'] as num?)?.toInt() ?? epoch;
        if (nextEpoch != epoch) {
          epoch = nextEpoch;
          _lastSeq = 0;
          image?.dispose();
          image = null;
        }
        state = msg['state'] as String? ?? state;
        actualMode =
            DesktopMode.values
                .where((m) => m.name == msg['mode'])
                .firstOrNull ??
            actualMode;
        active = state == 'active';
        if (active) {
          _attempt = 0;
        }
        if (active) {
          error = null;
        } else if (msg['message'] != null) {
          error = msg['message'] as String;
        }
        if (actualMode != DesktopMode.smooth) await _closeVideo();
      case 'info':
        if (msg['monitorId'] != null) monitorId = msg['monitorId'] as String;
        monitors = (msg['monitors'] as List? ?? [])
            .whereType<Map<String, dynamic>>()
            .toList();
      case 'notice':
        notice = msg['message'] as String?;
      case 'error':
        error = msg['message'] as String? ?? '桌面服務暫時無法使用';
        active = false;
      case 'cursor':
        if (msg['epoch'] != null && msg['epoch'] != epoch) return;
        cursorX = (msg['x'] as num?)?.toDouble() ?? cursorX;
        cursorY = (msg['y'] as num?)?.toDouble() ?? cursorY;
        cursorVisible = msg['visible'] == true;
        final shape = msg['shape'] as Map?;
        if (shape?['png'] is String &&
            (shape!['png'] as String).length <= 128 * 1024) {
          cursorPng = base64Decode(shape['png'] as String);
          cursorWidth = (shape['width'] as num?)?.toDouble() ?? 20;
          cursorHeight = (shape['height'] as num?)?.toDouble() ?? 20;
          cursorHotX = (shape['hotX'] as num?)?.toDouble() ?? 0;
          cursorHotY = (shape['hotY'] as num?)?.toDouble() ?? 0;
        }
        cursorRevision++;
      case 'video-format':
        width = (msg['width'] as num).toDouble();
        height = (msg['height'] as num).toDouble();
      case 'video-frame':
        updatedAt = DateTime.now();
      case 'offer':
        await _offer(msg['sdp'] as String, generation);
      case 'candidate':
        final candidate = RTCIceCandidate(
          msg['candidate'] as String,
          msg['mid'] as String? ?? '0',
          0,
        );
        if (_peer == null) {
          _candidates.add(candidate);
        } else {
          await _peer!.addCandidate(candidate);
        }
    }
    _notify();
  }

  Future<void> _frame(Uint8List packet, int generation) async {
    if (packet.length < 4 || packet.length > 20 * 1024 * 1024) {
      throw const FormatException();
    }
    final n = ByteData.sublistView(packet).getUint32(0, Endian.little);
    if (n > 1024 * 1024 || n + 4 > packet.length) throw const FormatException();
    final meta =
        jsonDecode(utf8.decode(Uint8List.sublistView(packet, 4, n + 4)))
            as Map<String, dynamic>;
    if (meta['epoch'] != epoch) return;
    final seq = (meta['seq'] as num).toInt(),
        w = (meta['width'] as num).toInt(),
        h = (meta['height'] as num).toInt();
    if (w < 1 ||
        h < 1 ||
        w > 1920 ||
        h > 1920 ||
        seq != _lastSeq + 1 ||
        (image == null && meta['full'] != true)) {
      throw const FormatException();
    }
    final images = <ui.Image>[];
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    if (meta['full'] != true && image != null) {
      canvas.drawImage(image!, ui.Offset.zero, ui.Paint());
    }
    try {
      for (final tile in (meta['tiles'] as List).cast<Map<String, dynamic>>()) {
        final x = (tile['x'] as num).toInt(),
            y = (tile['y'] as num).toInt(),
            tw = (tile['width'] as num).toInt(),
            th = (tile['height'] as num).toInt();
        final offset = (tile['offset'] as num).toInt(),
            length = (tile['length'] as num).toInt();
        if (x < 0 ||
            y < 0 ||
            tw < 1 ||
            th < 1 ||
            tw > 128 ||
            th > 128 ||
            x + tw > w ||
            y + th > h ||
            offset < 0 ||
            length < 1 ||
            n + 4 + offset + length > packet.length) {
          throw const FormatException();
        }
        final codec = await ui.instantiateImageCodec(
          Uint8List.sublistView(
            packet,
            n + 4 + offset,
            n + 4 + offset + length,
          ),
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        images.add(frame.image);
        if (frame.image.width != tw || frame.image.height != th) {
          throw const FormatException();
        }
        canvas.drawImage(
          frame.image,
          ui.Offset(x.toDouble(), y.toDouble()),
          ui.Paint(),
        );
      }
      final picture = recorder.endRecording();
      final next = await picture.toImage(w, h);
      picture.dispose();
      if (generation != _generation || disposed || meta['epoch'] != epoch) {
        next.dispose();
        return;
      }
      image?.dispose();
      image = next;
      width = w.toDouble();
      height = h.toDouble();
      _lastSeq = seq;
      updatedAt = DateTime.now();
      _frames++;
      _send({'type': 'ack', 'epoch': epoch, 'seq': seq});
      _notify();
    } finally {
      if (recorder.isRecording) recorder.endRecording().dispose();
      for (final img in images) {
        img.dispose();
      }
    }
  }

  Future<void> _offer(String sdp, int generation) async {
    final pendingCandidates = List<RTCIceCandidate>.of(_candidates);
    final offerEpoch = epoch;
    await _closeVideo();
    _candidates.addAll(pendingCandidates);
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    if (generation != _generation || disposed) {
      await renderer.dispose();
      return;
    }
    video = renderer;
    renderer.onFirstFrameRendered = () {
      if (generation == _generation &&
          identical(video, renderer) &&
          epoch == offerEpoch) {
        _send({'type': 'ack', 'epoch': offerEpoch, 'seq': 0});
        _notify();
      }
    };
    final peer = await createPeerConnection({'iceServers': <dynamic>[]});
    _peer = peer;
    peer.onIceCandidate = (candidate) {
      if (generation == _generation &&
          identical(_peer, peer) &&
          candidate.candidate != null) {
        _send({
          'type': 'candidate',
          'candidate': candidate.candidate,
          'mid': candidate.sdpMid,
          'epoch': offerEpoch,
        });
      }
    };
    peer.onTrack = (event) {
      if (generation == _generation &&
          identical(_peer, peer) &&
          event.streams.isNotEmpty) {
        renderer.srcObject = event.streams.first;
        _notify();
      }
    };
    peer.onConnectionState = (state) {
      if (generation == _generation &&
          identical(_peer, peer) &&
          state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) {
        _send({'type': 'videoFailed', 'epoch': offerEpoch});
      }
    };
    await peer.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    for (final candidate in _candidates) {
      await peer.addCandidate(candidate);
    }
    _candidates.clear();
    final answer = await peer.createAnswer();
    await peer.setLocalDescription(answer);
    if (generation == _generation && identical(_peer, peer)) {
      _send({'type': 'answer', 'sdp': answer.sdp, 'epoch': offerEpoch});
    }
  }

  Future<void> _videoStats() async {
    final peer = _peer;
    if (peer == null || disposed) return;
    try {
      for (final report in await peer.getStats()) {
        if (!identical(_peer, peer)) return;
        if (report.type != 'inbound-rtp' || report.values['kind'] == 'audio') {
          continue;
        }
        final values = report.values;
        final bytes = (values['bytesReceived'] as num?)?.toInt() ?? 0;
        bytesReceived += (bytes - _videoBytes).clamp(0, 100000000);
        _videoBytes = bytes;
        fps = (values['framesPerSecond'] as num?)?.toDouble() ?? fps;
        final received = (values['packetsReceived'] as num?)?.toDouble() ?? 0;
        final lost = (values['packetsLost'] as num?)?.toDouble() ?? 0;
        final loss = lost / (received + lost + 1);
        _send({
          'type': 'stats',
          'epoch': epoch,
          'loss': loss.clamp(0, 1),
          'bitrate': loss > .03 ? 2000000 : 4000000,
        });
      }
    } catch (_) {
      /* The peer can close while stats are in flight. */
    }
  }

  Future<void> _closeVideo() async {
    final peer = _peer, renderer = video;
    _peer = null;
    video = null;
    _videoBytes = 0;
    _candidates.clear();
    await peer?.close();
    await peer?.dispose();
    await renderer?.dispose();
  }

  void _lost(int generation) {
    if (generation != _generation || disposed) return;
    active = false;
    loading = false;
    state = 'disconnected';
    final socket = _socket;
    _socket = null;
    _socketAuthenticated = false;
    _sessionOptions = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(socket?.sink.close());
    _sessionId = null;
    _statsTimer?.cancel();
    unawaited(_closeVideo());
    _queueRetry();
    _notify();
  }

  void _queueRetry() {
    if (!visible || disposed) return;
    _retry?.cancel();
    _retry = Timer(
      Duration(
        milliseconds: [500, 1000, 2000, 4000, 8000][_attempt.clamp(0, 4)],
      ),
      () {
        unawaited(connect());
      },
    );
    _attempt++;
  }

  Future<void> disconnect() async {
    visible = false;
    ++_generation;
    _retry?.cancel();
    _statsTimer?.cancel();
    release();
    final socket = _socket, id = _sessionId;
    _socket = null;
    _socketAuthenticated = false;
    _sessionOptions = null;
    _sessionId = null;
    active = false;
    loading = false;
    _lastSeq = 0;
    state = 'disconnected';
    await _subscription?.cancel();
    _subscription = null;
    await socket?.sink.close();
    await _closeVideo();
    image?.dispose();
    image = null;
    width = 0;
    height = 0;
    cursorPng = null;
    if (id != null) {
      unawaited(
        _request(
          'DELETE',
          '/api/desktop/sessions/$id',
        ).catchError((_) => <String, dynamic>{}),
      );
    }
    _notify();
  }

  void _notify() {
    if (!disposed) notifyListeners();
  }

  @override
  void dispose() {
    unawaited(disconnect());
    disposed = true;
    _http.close();
    super.dispose();
  }
}
