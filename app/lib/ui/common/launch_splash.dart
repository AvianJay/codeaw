import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'codeaw_icon.dart';

/// Continues the native launch screen: types `>_` into the icon's bubble, then
/// zooms the bubble open onto [child] once [ready].
///
/// The first frame repeats the Android splash screen and the iOS launch
/// storyboard (both from tool/generate_icon.py), so the hand-over can't be
/// seen. The web has no native launch screen and shows [child] directly.
class LaunchSplash extends StatefulWidget {
  const LaunchSplash({super.key, required this.ready, required this.child});

  final bool ready;
  final Widget child;

  @override
  State<LaunchSplash> createState() => _LaunchSplashState();
}

class _LaunchSplashState extends State<LaunchSplash> with SingleTickerProviderStateMixin {
  Ticker? _ticker;
  late ui.FlutterView _view;
  late Brightness _brightness;
  var _done = kIsWeb;
  var _started = false;
  var _reduceMotion = false;
  var _skip = false;
  var _clock = Duration.zero;
  var _lastTick = Duration.zero;
  Duration? _exitStart;

  /// The first frame stays still while the native launch screen goes away. On
  /// iOS, Flutter fades the launch storyboard out over 0.2 s.
  Duration get _hold => Duration(milliseconds: defaultTargetPlatform == TargetPlatform.iOS ? 200 : 100);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _view = View.of(context);
    if (_started || _done) return;
    _started = true;
    final platform = _view.platformDispatcher;
    // The native launch screens can only follow the system, not the app's theme setting.
    _brightness = platform.platformBrightness;
    final features = platform.accessibilityFeatures;
    _reduceMotion = features.disableAnimations || features.reduceMotion;
    if (_reduceMotion) {
      _done = widget.ready;
    } else {
      _ticker = createTicker(_tick)..start();
    }
  }

  @override
  void didUpdateWidget(LaunchSplash oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_reduceMotion && widget.ready) _done = true;
  }

  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final step = elapsed - _lastTick;
    _lastTick = elapsed;
    // The first frames can come before the view has a size.
    if (_view.physicalSize.isEmpty) return;
    setState(() {
      // A slow frame shouldn't skip part of the animation.
      _clock += step < _maxStep ? step : _maxStep;
      final introEnd = _hold + _ms(_introLength);
      if (_exitStart == null && widget.ready && (_skip || _clock >= introEnd)) _exitStart = _clock;
      final exitStart = _exitStart;
      if (exitStart != null && _clock - exitStart >= _ms(_exitLength)) {
        _done = true;
        _ticker!.stop();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // The same Stack throughout, so that removing the overlay keeps the app's state.
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (!_done)
          AnnotatedRegion<SystemUiOverlayStyle>(
            value: _brightness == Brightness.dark ? _lightStatusIcons : _darkStatusIcons,
            child: ExcludeSemantics(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => _skip = true,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _SplashPainter(
                      surface: _brightness == Brightness.dark ? codeawSurfaceDark : codeawSurfaceLight,
                      time: _inMs(_clock - _hold),
                      exitAt: _exitStart == null ? null : _inMs(_exitStart! - _hold),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The most the animation advances in one frame.
const _maxStep = Duration(milliseconds: 100);

// Timeline in milliseconds after the hold.
const _introLength = 480.0;
const _exitLength = 450.0;
const _blinkPeriod = 1000.0; // while the app is still loading

// Exit phases, as fractions of the exit.
const _glyphOut = .15;
const _clearStart = .10;
const _clearEnd = .35;
const _anticipation = .22;
const _squeeze = .94;

const _darkStatusIcons = SystemUiOverlayStyle(
  statusBarColor: Color(0x00000000),
  statusBarIconBrightness: Brightness.dark,
  statusBarBrightness: Brightness.light,
);
const _lightStatusIcons = SystemUiOverlayStyle(
  statusBarColor: Color(0x00000000),
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
);

/// Logical pixels per icon unit: the launch screens draw the 108-unit icon
/// canvas in a 288 dp box, scaled so the circle is 160 dp wide.
const _unit = codeawSplashBox / 108 * codeawSplashScale;
const _center = Offset(54, 54);

final _bubble = _svgPath(codeawIconBubble);
final _chevron = _svgPath(codeawIconChevron);
final _underscore = _svgPath(codeawIconUnderscore);
final _circle = Path()..addOval(Rect.fromCircle(center: _center, radius: codeawIconCircleRadius));

Duration _ms(double ms) => Duration(microseconds: (ms * 1000).round());
double _inMs(Duration d) => d.inMicroseconds / 1000;
double _span(double t, double from, double to) => ((t - from) / (to - from)).clamp(0.0, 1.0);

class _SplashPainter extends CustomPainter {
  const _SplashPainter({required this.surface, required this.time, required this.exitAt});

  final Color surface;

  /// Milliseconds after the hold; negative during it.
  final double time;

  /// [time] when the exit began, or null before that.
  final double? exitAt;

  @override
  void paint(Canvas canvas, Size size) {
    final exitAt = this.exitAt;
    final exit = exitAt == null ? 0.0 : _span(time - exitAt, 0, _exitLength);
    // The zoom keeps the bubble body's centre in place.
    final pivot = codeawIconBubbleBody.center;
    final origin = size.center(Offset.zero) + (pivot - _center) * _unit;
    final scale = _unit * _zoom(exit, size, origin);
    Offset toIcon(Offset point) => (point - origin) / scale + pivot;
    final screen = Rect.fromPoints(toIcon(Offset.zero), toIcon(size.bottomRight(Offset.zero))).inflate(1);

    canvas.translate(origin.dx, origin.dy);
    canvas.scale(scale);
    canvas.translate(-pivot.dx, -pivot.dy);
    final background = Paint()..color = surface;
    final circle = Paint()..shader = _gradient(1);
    // Cut the bubble out only once it starts to clear: under the opaque fill, the
    // hole's anti-aliased edge would let a hairline of the app through.
    if (exit < _clearStart) {
      canvas.drawRect(screen, background);
      canvas.drawPath(_circle, circle);
    } else {
      canvas.drawPath(_without(Path()..addRect(screen), _bubble), background);
      canvas.drawPath(_without(_circle, _bubble), circle);
    }
    final fill = 1 - _span(exit, _clearStart, _clearEnd);
    if (fill > 0) canvas.drawPath(_bubble, Paint()..color = Colors.white.withValues(alpha: fill));

    final glyph = 1 - _span(exit, 0, _glyphOut);
    if (glyph == 0) return;
    final chevron = Curves.easeOutCubic.transform(_span(time, 0, 180));
    if (chevron > 0) {
      canvas.drawPath(_chevron.shift(Offset(-4 * (1 - chevron), 0)), Paint()..shader = _gradient(glyph * chevron));
    }
    final underscore = Curves.easeOutCubic.transform(_span(time, 140, 220));
    // The cursor stops blinking when the exit starts.
    if (underscore > 0 && !_cursorOff(exitAt ?? time)) {
      canvas.drawPath(_underscore.shift(Offset(-2 * (1 - underscore), 0)), Paint()..shader = _gradient(glyph * underscore));
    }
  }

  @override
  bool shouldRepaint(_SplashPainter old) => old.time != time || old.exitAt != exitAt || old.surface != surface;
}

/// The icon gradient over the whole 108-unit canvas, so the glyph reads as cut out.
ui.Gradient _gradient(double opacity) => ui.Gradient.linear(Offset.zero, const Offset(108, 108), [
  for (final color in codeawIconGradient) color.withValues(alpha: opacity),
]);

Path _without(Path outer, Path inner) => Path()
  ..fillType = PathFillType.evenOdd
  ..addPath(outer, Offset.zero)
  ..addPath(inner, Offset.zero);

bool _cursorOff(double time) =>
    time < _introLength ? time >= 340 && time < 420 : (time - _introLength) % _blinkPeriod >= _blinkPeriod / 2;

/// The bubble first draws back a little, then grows until its body covers the screen.
double _zoom(double exit, Size size, Offset origin) {
  if (exit <= 0) return 1;
  if (exit < _anticipation) return 1 - (1 - _squeeze) * Curves.easeOutCubic.transform(exit / _anticipation);
  final t = Curves.easeIn.transform((exit - _anticipation) / (1 - _anticipation));
  // Interpolating the logarithm makes the growth look even.
  return math.exp(math.log(_squeeze) + (math.log(_cover(size, origin)) - math.log(_squeeze)) * t);
}

/// The zoom at which the bubble body, minus its rounded corners, covers the screen.
double _cover(Size size, Offset origin) {
  final inset = codeawIconBubbleRadius * (1 - math.sqrt1_2);
  final halfWidth = codeawIconBubbleBody.width / 2 - inset;
  final halfHeight = codeawIconBubbleBody.height / 2 - inset;
  final reachX = math.max(origin.dx, size.width - origin.dx);
  final reachY = math.max(origin.dy, size.height - origin.dy);
  return 1.02 * math.max(reachX / (halfWidth * _unit), reachY / (halfHeight * _unit));
}

/// Builds a [Path] from the absolute M, L, A, C and Z commands that
/// tool/generate_icon.py writes.
Path _svgPath(String data) {
  final path = Path();
  final tokens = RegExp(r'[A-Za-z]|-?[\d.]+').allMatches(data).map((m) => m[0]!).toList();
  var i = 0;
  double next() => double.parse(tokens[i++]);
  while (i < tokens.length) {
    switch (tokens[i++]) {
      case 'M':
        path.moveTo(next(), next());
      case 'L':
        path.lineTo(next(), next());
      case 'C':
        path.cubicTo(next(), next(), next(), next(), next(), next());
      case 'A':
        final radius = Radius.elliptical(next(), next());
        final rotation = next();
        final largeArc = next() != 0;
        final clockwise = next() != 0;
        path.arcToPoint(Offset(next(), next()), radius: radius, rotation: rotation, largeArc: largeArc, clockwise: clockwise);
      case 'Z':
        path.close();
      case final command:
        throw FormatException('Unsupported path command $command', data);
    }
  }
  return path;
}
