import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

enum _Gesture { idle, single, pair, pairEnding, suppressed }

enum _PairAction { pending, scroll, pinch }

/// Touchpad input from global logical pixels, independent of pointer-event
/// transforms. Cursor prediction stays local until remote echoes settle.
class DesktopTrackpadGestures {
  DesktopTrackpadGestures({
    required this.send,
    required this.onCursorChanged,
    this.onPinchStart,
    this.onPinchUpdate,
    this.onPinchEnd,
  });

  final void Function(Map<String, dynamic>) send;
  final void Function(Offset) onCursorChanged;
  final void Function(Offset initialGlobalFocal)? onPinchStart;
  final void Function(double scaleFromInitialSpan, Offset currentGlobalFocal)?
  onPinchUpdate;
  final void Function()? onPinchEnd;

  static const _slop = 8.0;
  static const _holdDelay = Duration(milliseconds: 450);
  static const _frameDelay = Duration(milliseconds: 16);
  static const _echoGrace = Duration(milliseconds: 750);
  final _points = <int, Offset>{};
  final _origins = <int, Offset>{};
  Size _movementSize = Size.zero;
  Offset _cursor = const Offset(.5, .5);
  Offset? _pendingPointer;
  Offset _pendingWheel = Offset.zero;
  Offset _pairInitialFocal = Offset.zero, _pairLastFocal = Offset.zero;
  double _pairInitialSpan = 0;
  bool _pairDirty = false, _pinchActive = false;
  _Gesture _gesture = _Gesture.idle;
  _PairAction _pairAction = _PairAction.pending;
  Timer? _hold, _frame, _remoteGrace;
  bool _tapEligible = false;
  bool _leftHeld = false;
  bool _disposed = false;

  Offset get cursor => _cursor;
  bool get hasContacts => _points.isNotEmpty;

  /// Set the logical-pixel movement span for the normalized cursor axes.
  /// The caller derives this from the displayed desktop and viewport, excluding
  /// letterboxing so a diagonal finger movement remains diagonal on screen.
  /// Touches may originate anywhere in the outer viewport, including its bars.
  void setViewport(Size movementSize) {
    if (movementSize.width.isFinite &&
        movementSize.height.isFinite &&
        movementSize.width > 0 &&
        movementSize.height > 0) {
      _movementSize = movementSize;
    }
  }

  void syncRemoteCursor(Offset position) {
    if (_disposed || _points.isNotEmpty || _remoteGrace != null) return;
    _setCursor(position);
  }

  /// Transfer a locally controlled mouse position before starting a touch
  /// gesture. Unlike remote frames, local input bypasses the echo grace period.
  /// An active touch must be cancelled before changing its input source.
  void adoptLocalCursor(Offset position) {
    if (_disposed || hasContacts || !_finite(position)) return;
    _setCursor(position);
    _deferRemoteCursor();
  }

  void pointerDown(int id, Offset global) {
    if (_disposed || _points.containsKey(id) || !_finite(global)) return;
    _points[id] = global;
    _origins[id] = global;
    _deferRemoteCursor();
    if (_points.length >= 3) {
      _abortGesture();
      return;
    }
    if (_gesture == _Gesture.suppressed || _gesture == _Gesture.pairEnding) {
      _tapEligible = false;
      _gesture = _Gesture.suppressed;
      return;
    }
    _hold?.cancel();
    if (_points.length == 1) {
      _gesture = _Gesture.single;
      _tapEligible = true;
      _hold = Timer(_holdDelay, () {
        _hold = null;
        if (_gesture != _Gesture.single || !_tapEligible) return;
        _tapEligible = false;
        _leftHeld = true;
        _button('left', true);
      });
      return;
    }
    // Adding another contact during a held drag must not release its button.
    // Wait for all contacts to lift, without changing to a scroll or a click.
    if (_leftHeld) {
      _flush();
      _gesture = _Gesture.suppressed;
      return;
    }
    _flush();
    _gesture = _Gesture.pair;
    _tapEligible = true;
    _pairAction = _PairAction.pending;
    _pairDirty = false;
    _pairInitialFocal = _pairLastFocal = _focal;
    _pairInitialSpan = _span;
    // Start the two-finger slop at the moment the second contact joins.
    _origins.addAll(_points);
    _hold = Timer(_holdDelay, () {
      _hold = null;
      _tapEligible = false;
    });
  }

  void pointerMove(int id, Offset global) {
    final previous = _points[id];
    if (_disposed || previous == null || !_finite(global)) return;
    _points[id] = global;
    _deferRemoteCursor();
    if (_gesture == _Gesture.single) {
      if ((global - _origins[id]!).distance > _slop) {
        _tapEligible = false;
        _hold?.cancel();
        _hold = null;
      }
      if (_movementSize.isEmpty) return;
      final delta = global - previous;
      _setCursor(
        _cursor +
            Offset(
              delta.dx / _movementSize.width,
              delta.dy / _movementSize.height,
            ),
      );
      _pendingPointer = _cursor;
      _queueFrame();
    } else if (_gesture == _Gesture.pair) {
      if ((global - _origins[id]!).distance > _slop) {
        _tapEligible = false;
        _hold?.cancel();
        _hold = null;
      }
      // Decide from the complete pair at the next frame, not the intermediate
      // separation after just the first of two sequential pointer events.
      _pairDirty = true;
      _queueFrame();
    } else if (_gesture == _Gesture.pairEnding &&
        (global - _origins[id]!).distance > _slop) {
      // A remaining finger can finish lifting, but cannot begin a new gesture
      // or turn a staggered drag into a right click.
      _tapEligible = false;
    }
  }

  void pointerUp(int id) {
    if (_disposed || !_points.containsKey(id)) return;
    if (_gesture == _Gesture.pair) {
      _flush();
      _endPinch();
    }
    _points.remove(id);
    _origins.remove(id);
    _deferRemoteCursor();
    if (_points.isNotEmpty) {
      if (_gesture == _Gesture.pair) _gesture = _Gesture.pairEnding;
      return;
    }
    _hold?.cancel();
    _hold = null;
    _flush();
    if (_leftHeld) {
      _leftHeld = false;
      _button('left', false);
    } else if (_tapEligible) {
      final button = switch (_gesture) {
        _Gesture.single => 'left',
        _Gesture.pair || _Gesture.pairEnding => 'right',
        _ => null,
      };
      if (button != null) {
        _button(button, true);
        _button(button, false);
      }
    }
    _resetGesture();
  }

  void pointerCancel(int id) {
    if (_disposed || !_points.containsKey(id)) return;
    _points.remove(id);
    _origins.remove(id);
    _abortGesture();
    if (_points.isEmpty) _resetGesture();
  }

  /// Release input on focus loss, disconnect, or leaving the desktop page.
  void cancel() {
    if (_disposed) return;
    _abortGesture();
    _points.clear();
    _origins.clear();
    _resetGesture();
  }

  void dispose() {
    if (_disposed) return;
    cancel();
    _remoteGrace?.cancel();
    _remoteGrace = null;
    _disposed = true;
  }

  void _setCursor(Offset position) {
    if (!_finite(position)) return;
    final next = Offset(position.dx.clamp(0, 1), position.dy.clamp(0, 1));
    if (next == _cursor) return;
    _cursor = next;
    onCursorChanged(next);
  }

  static bool _finite(Offset position) =>
      position.dx.isFinite && position.dy.isFinite;

  void _deferRemoteCursor() {
    _remoteGrace?.cancel();
    _remoteGrace = Timer(_echoGrace, () => _remoteGrace = null);
  }

  void _queueFrame() => _frame ??= Timer(_frameDelay, _flush);

  Offset get _focal => (_points.values.first + _points.values.last) / 2;
  double get _span => (_points.values.first - _points.values.last).distance;

  void _processPair() {
    if (!_pairDirty || _gesture != _Gesture.pair || _points.length != 2) return;
    _pairDirty = false;
    final focal = _focal, span = _span;
    if (!_finite(focal) || !span.isFinite) return;
    if (_pairAction == _PairAction.pending &&
        _pairInitialSpan < _slop &&
        span >= _slop) {
      // Coincident contacts have no meaningful scale. Establish a usable span
      // first, then measure subsequent pinch movement from that baseline.
      _pairInitialSpan = span;
      _pairInitialFocal = _pairLastFocal = focal;
      return;
    }
    if (_pairAction == _PairAction.pending) {
      final spanChange = (span - _pairInitialSpan).abs();
      final translation = (focal - _pairInitialFocal).distance;
      final pinchSlop = math.max(12.0, _pairInitialSpan * .08);
      if (_pairInitialSpan >= _slop &&
          spanChange >= pinchSlop &&
          spanChange > translation * 1.25) {
        _pairAction = _PairAction.pinch;
        _pinchActive = true;
        _pendingWheel = Offset.zero;
        onPinchStart?.call(_pairInitialFocal);
      } else if (translation > _slop && translation > spanChange * .8) {
        _pairAction = _PairAction.scroll;
      }
      if (_pairAction != _PairAction.pending) {
        _tapEligible = false;
        _hold?.cancel();
        _hold = null;
      }
    }
    // Recognition is locked until the pair ends: changing grip mid-scroll
    // cannot accidentally zoom, and translating a pinch cannot scroll remotely.
    if (_pairAction == _PairAction.scroll) {
      final delta = focal - _pairLastFocal;
      _pendingWheel += Offset(-delta.dx * 3, delta.dy * 3);
      _pairLastFocal = focal;
    } else if (_pairAction == _PairAction.pinch) {
      final scale = span / _pairInitialSpan;
      if (scale.isFinite) onPinchUpdate?.call(scale, focal);
    }
  }

  void _endPinch() {
    if (!_pinchActive) return;
    _pinchActive = false;
    onPinchEnd?.call();
  }

  void _flush() {
    _frame?.cancel();
    _frame = null;
    _processPair();
    final pointer = _pendingPointer;
    _pendingPointer = null;
    if (pointer != null) {
      send({'kind': 'pointer', 'x': pointer.dx, 'y': pointer.dy});
    }
    final wheel = _pendingWheel;
    final wholeX = wheel.dx.truncate();
    final wholeY = wheel.dy.truncate();
    final dx = wholeX.clamp(-1200, 1200);
    final dy = wholeY.clamp(-1200, 1200);
    // Slow trackpad movement often contributes less than a wheel unit per
    // frame. Keep its fraction until later input completes a whole unit.
    // Truncation leaves a remainder that cannot emit opposite-direction input
    // when a click or pointer-up flushes the queue without any new movement.
    _pendingWheel = Offset(wheel.dx - wholeX, wheel.dy - wholeY);
    if (dx != 0 || dy != 0) {
      send({
        'kind': 'wheel',
        'delta': dy,
        'deltaX': dx,
        'x': _cursor.dx,
        'y': _cursor.dy,
      });
    }
  }

  void _button(String button, bool down) {
    _flush();
    send({
      'kind': 'button',
      'button': button,
      'down': down,
      'x': _cursor.dx,
      'y': _cursor.dy,
    });
    _deferRemoteCursor();
  }

  void _abortGesture() {
    _hold?.cancel();
    _hold = null;
    _frame?.cancel();
    _frame = null;
    _pendingPointer = null;
    _pendingWheel = Offset.zero;
    _pairDirty = false;
    _endPinch();
    if (_leftHeld) {
      _leftHeld = false;
      _button('left', false);
    }
    send({'kind': 'release'});
    _gesture = _Gesture.suppressed;
    _tapEligible = false;
    _deferRemoteCursor();
  }

  void _resetGesture() {
    _gesture = _Gesture.idle;
    _tapEligible = false;
    _pairAction = _PairAction.pending;
    _pairDirty = false;
    _pendingWheel = Offset.zero;
  }
}
