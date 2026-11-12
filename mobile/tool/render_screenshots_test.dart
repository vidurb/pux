// Renders the scenes in lib/screenshots/scenes.dart to PNGs without a device:
// the Google Play sets, and the few the README shows. Run it through
// tool/render_screenshots.sh. It lives outside test/ so `flutter test` doesn't
// write files.
//
// Widget tests draw text in a placeholder font and have no system fonts to
// fall back on, so this loads Roboto and the Material icons from the Flutter
// SDK, plus a font from the host for the symbols Roboto lacks, such as "→".
// Scenes render as on Android.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/screenshots/png.dart';
import 'package:pux/screenshots/scenes.dart';
import 'package:pux/src/theme.dart';

/// A set of screenshots: pixel size, device pixel ratio, and which scenes.
typedef _Shots = ({Size pixels, double ratio, List<Scene> scenes});

// Play takes 2 to 8 screenshots per device type. These are 9:16, which every
// slot accepts, and at least 1080px on the short side.
final _sets = <String, _Shots>{
  'play/phone': (
    pixels: const Size(1080, 1920),
    ratio: 2.625,
    scenes: Scene.values,
  ),
  'play/tablet-7': (
    pixels: const Size(1080, 1920),
    ratio: 1.5,
    scenes: Scene.values,
  ),
  'play/tablet-10': (
    pixels: const Size(1440, 2560),
    ratio: 2,
    scenes: Scene.values,
  ),
  'readme': (
    pixels: const Size(618, 1098),
    ratio: 1.5,
    scenes: [Scene.notification, Scene.devices, Scene.forwarding],
  ),
};

/// Fonts with arrows and other symbols, on macOS and on Debian or Ubuntu.
/// PUX_SYMBOL_FONT overrides them.
const _symbolFonts = [
  '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
  '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
  '/usr/share/fonts/dejavu/DejaVuSans.ttf',
];

void main() {
  final out =
      Platform.environment['PUX_SCREENSHOTS_OUT'] ?? 'build/screenshots';
  late ThemeData theme;

  setUpAll(() async {
    final base = puxTheme();
    theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamilyFallback: await _loadFonts()),
    );
  });

  for (final MapEntry(key: name, value: shots) in _sets.entries) {
    for (final (index, scene) in shots.scenes.indexed) {
      final file = name == 'readme'
          ? '$out/$name/app-${scene.name}.png'
          : '$out/$name/${'${index + 1}'.padLeft(2, '0')}-${scene.name}.png';
      testWidgets(file, (tester) async {
        tester.view.physicalSize = shots.pixels;
        tester.view.devicePixelRatio = shots.ratio;
        // Room for the status bar, which isn't drawn.
        tester.view.padding = FakeViewPadding(top: 24 * shots.ratio);
        addTearDown(tester.view.reset);

        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: ProviderScope(
              child: ScreenshotApp(sceneName: scene.name, theme: theme),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(key),
        );
        final png = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: shots.ratio);
          try {
            final rgba = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            return encodeOpaquePng(
              rgba!.buffer.asUint8List(),
              image.width,
              image.height,
            );
          } finally {
            image.dispose();
          }
        });
        File(file)
          ..createSync(recursive: true)
          ..writeAsBytesSync(png!);
      });
    }
  }
}

/// Loads the fonts and returns the fallback families for the theme.
Future<List<String>> _loadFonts() async {
  final fonts = _materialFonts();
  final roboto = FontLoader('Roboto');
  for (final weight in [
    'Thin',
    'Light',
    'Regular',
    'Medium',
    'Bold',
    'Black',
  ]) {
    roboto.addFont(_read('${fonts.path}/Roboto-$weight.ttf'));
  }
  await roboto.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(_read('${fonts.path}/MaterialIcons-Regular.otf'))).load();

  final override = Platform.environment['PUX_SYMBOL_FONT'];
  final symbols = [
    ?override,
    ..._symbolFonts,
  ].where((path) => File(path).existsSync()).firstOrNull;
  if (symbols == null) {
    stderr.writeln(
      'No symbol font found, so "→" will show as a box. '
      'Set PUX_SYMBOL_FONT to a font that has it, such as DejaVu Sans.',
    );
    return const [];
  }
  await (FontLoader('Symbols')..addFont(_read(symbols))).load();
  return const ['Symbols'];
}

Future<ByteData> _read(String path) async =>
    ByteData.sublistView(await File(path).readAsBytes());

/// bin/cache/artifacts/material_fonts in the Flutter SDK, found from
/// FLUTTER_ROOT or from the test runner, which lives in the same cache.
Directory _materialFonts() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null) {
    final fonts = Directory('$root/bin/cache/artifacts/material_fonts');
    if (fonts.existsSync()) return fonts;
  }
  var dir = File(Platform.resolvedExecutable).parent;
  while (dir.parent.path != dir.path) {
    final fonts = Directory('${dir.path}/material_fonts');
    if (fonts.existsSync()) return fonts;
    dir = dir.parent;
  }
  throw StateError(
    "Can't find the Flutter SDK's material_fonts. Set FLUTTER_ROOT.",
  );
}
