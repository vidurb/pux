import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../src/screens/enroll_chooser_screen.dart';
import '../src/screens/forwarding_help_screen.dart';
import '../src/theme.dart';

// Brand palette, as on the website (brand/README.md).
const _pine = Color(0xFF0E3B32);
const _pineDeep = Color(0xFF0A2C25);
const _pineLine = Color(0xFF2C6355);
const _mint = Color(0xFFDDF3D6);
const _paper = Color(0xFFF5F8F1);
const _ink = Color(0xFF0C1F1B);
const _muted = Color(0xFF47574F);

// A fictional sender: App Review can reject screenshots that show a real
// bank's name. The format matches what the notification extension shows.
const demoSender = 'Northwind Bank';
const demoCode = '482913';
const demoInbox = 'q7m2kx9fz4hw1ta8pe3nvc6r@pux.vidur.xyz';

/// One App Store screenshot. The order here is the order in the store.
enum Scene {
  notification(
    'Bank OTPs on every device',
    'Even when the phone with your SIM has no signal.',
  ),
  noSignal(
    'No signal? The code still arrives',
    'pux delivers over Wi-Fi or any other internet connection.',
  ),
  devices(
    'On your computer and every phone',
    'Add a second phone or your computer, and each one gets every code.',
  ),
  setup(
    'Set up in a minute',
    'Create a relay on your phone. Its keys are generated right there.',
  ),
  forwarding(
    "Forward only your bank's codes",
    'Step-by-step filters for your email.',
  ),
  privacy(
    'Private by design',
    'End-to-end encrypted, with nothing to sign up for.',
  );

  const Scene(this.headline, this.subline);

  final String headline;
  final String subline;

  static Scene? byName(String name) {
    for (final scene in values) {
      if (scene.name == name) return scene;
    }
    return null;
  }
}

class ScreenshotApp extends StatelessWidget {
  const ScreenshotApp({super.key, required this.sceneName, this.theme});

  final String sceneName;

  /// Defaults to the app's theme. tool/render_screenshots_test.dart adds a
  /// fallback font to it, since widget tests have no system fonts.
  final ThemeData? theme;

  @override
  Widget build(BuildContext context) {
    final scene = Scene.byName(sceneName);
    return MaterialApp(
      title: 'pux',
      debugShowCheckedModeBanner: false,
      theme: theme ?? puxTheme(),
      home: scene == null
          ? _UnknownScene(name: sceneName)
          : SceneView(scene: scene),
    );
  }
}

/// A full-screen scene: headline on the brand background, then a mock.
///
/// Everything is sized from [k], so the same layout fills a 6.9" iPhone
/// (440 x 956 points, k = 1) and a 13" iPad (1032 x 1376 points, k = 1.72).
class SceneView extends StatelessWidget {
  const SceneView({super.key, required this.scene});

  final Scene scene;

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: _scene(top),
    );
  }

  Widget _scene(double top) {
    return Material(
      color: _pine,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final k = math.min(
            constraints.maxWidth / 440,
            constraints.maxHeight / 800,
          );
          return Center(
            child: SizedBox(
              width: math.min(constraints.maxWidth, 440 * k),
              child: Padding(
                padding: EdgeInsets.fromLTRB(28 * k, top + 28 * k, 28 * k, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    PuxMark(height: 30 * k, color: _mint),
                    SizedBox(height: 22 * k),
                    Text(
                      scene.headline,
                      style: TextStyle(
                        color: _paper,
                        fontSize: 40 * k,
                        fontWeight: FontWeight.w800,
                        height: 1.08,
                        letterSpacing: -0.6 * k,
                      ),
                    ),
                    SizedBox(height: 12 * k),
                    Text(
                      scene.subline,
                      style: TextStyle(
                        color: _mint,
                        fontSize: 19 * k,
                        height: 1.35,
                      ),
                    ),
                    SizedBox(height: 36 * k),
                    Expanded(child: _mockFor(scene, k)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _mockFor(Scene scene, double k) => switch (scene) {
    Scene.notification => _LockScreen(k: k),
    Scene.noSignal => _FitDown(child: _NoSignal(k: k)),
    Scene.devices => _Devices(k: k),
    Scene.setup => _PhoneFrame(k: k, child: const EnrollChooserScreen()),
    Scene.forwarding => _PhoneFrame(
      k: k,
      child: const ForwardingHelpScreen(inbox: demoInbox),
    ),
    Scene.privacy => _FitDown(child: _PrivacyPoints(k: k)),
  };
}

/// The pux mark (brand/pux-mark.svg): a "p" whose bowl is a keyhole.
class PuxMark extends StatelessWidget {
  const PuxMark({super.key, required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: height * 240 / 336,
    child: CustomPaint(painter: _MarkPainter(color)),
  );
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Path data from brand/pux-mark.svg, whose viewBox starts at (136, 96).
    canvas.scale(size.width / 240, size.height / 336);
    canvas.translate(-136, -96);
    final path = Path()
      ..fillType = PathFillType.evenOdd
      ..moveTo(136, 96)
      ..lineTo(256, 96)
      ..arcToPoint(const Offset(256, 336), radius: const Radius.circular(120))
      ..lineTo(208, 336)
      ..lineTo(208, 432)
      ..lineTo(136, 432)
      ..close()
      ..moveTo(256, 154)
      ..arcToPoint(const Offset(278, 232), radius: const Radius.circular(42))
      ..lineTo(294, 288)
      ..lineTo(218, 288)
      ..lineTo(234, 232)
      ..arcToPoint(const Offset(256, 154), radius: const Radius.circular(42))
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_MarkPainter old) => old.color != color;
}

/// The app icon: the mark on pine, in a rounded square.
class _AppIcon extends StatelessWidget {
  const _AppIcon({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: _pine,
      borderRadius: BorderRadius.circular(size * 0.23),
    ),
    child: PuxMark(height: size * 0.6, color: _mint),
  );
}

/// A notification as the extension shows it: "OTP from" the sender, and the code.
class _NotificationCard extends StatelessWidget {
  const _NotificationCard({required this.k, this.scale = 1});

  final double k;
  final double scale;

  @override
  Widget build(BuildContext context) {
    final u = k * scale;
    return Container(
      padding: EdgeInsets.all(14 * u),
      decoration: BoxDecoration(
        color: _paper.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(22 * u),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 18 * u,
            offset: Offset(0, 6 * u),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AppIcon(size: 38 * u),
          SizedBox(width: 12 * u),
          Expanded(
            child: Column(
              // Hug the text: in the devices scene the card has room to grow.
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'pux',
                      style: TextStyle(
                        color: _muted,
                        fontSize: 13 * u,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'now',
                      style: TextStyle(color: _muted, fontSize: 13 * u),
                    ),
                  ],
                ),
                SizedBox(height: 2 * u),
                Text(
                  'OTP from $demoSender',
                  style: TextStyle(
                    color: _ink,
                    fontSize: 16 * u,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  demoCode,
                  style: TextStyle(
                    color: _ink,
                    fontSize: 30 * u,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 3 * u,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "No service" with Wi-Fi on, as a status line.
class _ConnectionLine extends StatelessWidget {
  const _ConnectionLine({required this.k});

  final double k;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: _mint,
      fontSize: 15 * k,
      fontWeight: FontWeight.w600,
    );
    Widget item(IconData icon, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: _mint, size: 20 * k),
        SizedBox(width: 6 * k),
        Text(label, style: style),
      ],
    );
    return Wrap(
      spacing: 18 * k,
      runSpacing: 6 * k,
      children: [
        item(Icons.signal_cellular_off, 'No service'),
        item(Icons.wifi, 'Hotel Wi-Fi'),
      ],
    );
  }
}

class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.k});

  final double k;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: EdgeInsets.fromLTRB(18 * k, 26 * k, 18 * k, 0),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_pineDeep, Color(0xFF061D18)],
        ),
        borderRadius: BorderRadius.vertical(top: Radius.circular(40 * k)),
        border: Border.all(color: _pineLine, width: 1.5 * k),
      ),
      child: Column(
        children: [
          _ConnectionLine(k: k),
          SizedBox(height: 22 * k),
          Text(
            '9:41',
            style: TextStyle(
              color: _paper,
              fontSize: 86 * k,
              fontWeight: FontWeight.w600,
              height: 1,
            ),
          ),
          SizedBox(height: 6 * k),
          Text(
            'Wednesday 11 November',
            style: TextStyle(color: _mint, fontSize: 18 * k),
          ),
          SizedBox(height: 34 * k),
          _NotificationCard(k: k),
        ],
      ),
    );
  }
}

class _NoSignal extends StatelessWidget {
  const _NoSignal({required this.k});

  final double k;

  @override
  Widget build(BuildContext context) {
    final label = TextStyle(
      color: _mint,
      fontSize: 14 * k,
      fontWeight: FontWeight.w600,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ConnectionLine(k: k),
        SizedBox(height: 22 * k),
        _Panel(
          k: k,
          color: _pineDeep,
          border: _pineLine,
          children: [
            Text('Text message', style: label),
            SizedBox(height: 10 * k),
            Text(
              "No service. The SMS hasn't arrived.",
              style: TextStyle(color: _paper, fontSize: 19 * k),
            ),
          ],
        ),
        SizedBox(height: 14 * k),
        _Panel(
          k: k,
          color: _paper,
          children: [
            Text('pux, over Wi-Fi', style: label.copyWith(color: _muted)),
            SizedBox(height: 10 * k),
            Text(
              'OTP from $demoSender',
              style: TextStyle(
                color: _ink,
                fontSize: 18 * k,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              demoCode,
              style: TextStyle(
                color: _ink,
                fontSize: 50 * k,
                fontWeight: FontWeight.w700,
                letterSpacing: 5 * k,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.k,
    required this.color,
    this.border,
    required this.children,
  });

  final double k;
  final Color color;
  final Color? border;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(20 * k),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20 * k),
      border: border == null
          ? null
          : Border.all(color: border!, width: 1.5 * k),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );
}

/// A laptop with the code in a notification, and a phone in front of it.
class _Devices extends StatelessWidget {
  const _Devices({required this.k});

  final double k;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final screenHeight = (width - 20 * k) * 0.64;
        final phoneWidth = width * 0.46;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            Column(
              children: [
                Container(
                  height: screenHeight,
                  margin: EdgeInsets.symmetric(horizontal: 10 * k),
                  padding: EdgeInsets.all(14 * k),
                  alignment: Alignment.topRight,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [Color(0xFFE8F1E4), Color(0xFFC9DEC4)],
                    ),
                    borderRadius: BorderRadius.circular(16 * k),
                    border: Border.all(
                      color: const Color(0xFF081A16),
                      width: 8 * k,
                    ),
                  ),
                  child: SizedBox(
                    width: width * 0.62,
                    child: _NotificationCard(k: k, scale: 0.72),
                  ),
                ),
                Container(
                  height: 12 * k,
                  decoration: BoxDecoration(
                    color: const Color(0xFF9DB3A6),
                    borderRadius: BorderRadius.vertical(
                      bottom: Radius.circular(10 * k),
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              right: 4 * k,
              top: screenHeight * 0.62,
              child: Container(
                width: phoneWidth,
                height: phoneWidth * 2.05,
                padding: EdgeInsets.fromLTRB(6 * k, 30 * k, 6 * k, 6 * k),
                decoration: BoxDecoration(
                  color: _pineDeep,
                  borderRadius: BorderRadius.circular(30 * k),
                  border: Border.all(
                    color: const Color(0xFF081A16),
                    width: 7 * k,
                  ),
                  boxShadow: [
                    BoxShadow(color: Colors.black38, blurRadius: 24 * k),
                  ],
                ),
                alignment: Alignment.topCenter,
                child: _NotificationCard(k: k, scale: 0.56),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A real app screen at iPhone size, in a phone outline cut off at the bottom.
class _PhoneFrame extends StatelessWidget {
  const _PhoneFrame({required this.k, required this.child});

  // Narrower than a real iPhone, so the screen's text reads at store size.
  static const _screen = Size(340, 736);

  final double k;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = math.min(constraints.maxWidth * 0.86, 360 * k);
        final height = width * _screen.height / _screen.width;
        final border = 9 * k;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            maxHeight: height,
            child: Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: const Color(0xFF081A16),
                borderRadius: BorderRadius.circular(48 * k),
              ),
              padding: EdgeInsets.all(border),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(48 * k - border),
                child: FittedBox(
                  child: SizedBox.fromSize(
                    size: _screen,
                    child: MediaQuery(
                      data: const MediaQueryData(
                        size: _screen,
                        padding: EdgeInsets.only(top: 54, bottom: 34),
                        viewPadding: EdgeInsets.only(top: 54, bottom: 34),
                      ),
                      child: child,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PrivacyPoints extends StatelessWidget {
  const _PrivacyPoints({required this.k});

  final double k;

  static const _points = [
    (
      'End-to-end encrypted',
      "Codes are sealed for your devices. The server can't open them.",
    ),
    ('No account', 'No name, email address or password.'),
    (
      'No stored mail',
      'Emails are read in memory to find the code, then dropped.',
    ),
    ('No trackers', 'No analytics and no ads.'),
    ('Open source', 'Read the code, or run your own server.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final (title, detail) in _points)
          Padding(
            padding: EdgeInsets.only(bottom: 22 * k),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle, color: _mint, size: 28 * k),
                SizedBox(width: 14 * k),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          color: _paper,
                          fontSize: 20 * k,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 2 * k),
                      Text(
                        detail,
                        style: TextStyle(
                          color: _mint,
                          fontSize: 16 * k,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Places [child] a little above the middle of the space left, shrinking it
/// if it doesn't fit, so a long caption or a wider font never pushes a mock
/// off the screen.
class _FitDown extends StatelessWidget {
  const _FitDown({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => Align(
      alignment: const Alignment(-1, -0.35),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: SizedBox(width: constraints.maxWidth, child: child),
      ),
    ),
  );
}

class _UnknownScene extends StatelessWidget {
  const _UnknownScene({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: Text(
        'Unknown scene "$name". Use one of: ${Scene.values.map((s) => s.name).join(', ')}',
        textAlign: TextAlign.center,
      ),
    ),
  );
}
