import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/screenshots/scenes.dart';

/// App Store screenshot sizes in logical pixels, with their scale.
const _devices = {
  'iPhone 6.3"': (Size(402, 874), 3.0),
  'iPhone 6.9"': (Size(440, 956), 3.0),
  'iPad 13"': (Size(1032, 1376), 2.0),
};

void main() {
  for (final MapEntry(key: device, value: (size, ratio)) in _devices.entries) {
    for (final scene in Scene.values) {
      testWidgets('${scene.name} lays out on $device', (tester) async {
        tester.view.physicalSize = size * ratio;
        tester.view.devicePixelRatio = ratio;
        tester.view.padding = FakeViewPadding(
          top: 62 * ratio,
          bottom: 34 * ratio,
        );
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(child: ScreenshotApp(sceneName: scene.name)),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(scene.headline), findsOneWidget);
      });
    }
  }

  testWidgets('an unknown scene lists the valid names', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: ScreenshotApp(sceneName: 'nope')),
    );
    expect(find.textContaining('Unknown scene "nope"'), findsOneWidget);
    expect(find.textContaining('notification'), findsOneWidget);
  });

  test('scene names are unique and resolve', () {
    for (final scene in Scene.values) {
      expect(Scene.byName(scene.name), scene);
    }
    expect(Scene.byName('missing'), isNull);
  });
}
