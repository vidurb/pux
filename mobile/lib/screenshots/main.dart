import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'scenes.dart';

/// Entry point for App Store screenshots, never shipped in the real app.
///
/// It shows one scene and touches no storage, network or Firebase.
///
/// The scene name comes from a `pux_scene` file in the app's temporary
/// directory, which `ios/scripts/app_store_screenshots.sh` writes into the
/// simulator before each launch, so one build covers every scene. (A Flutter
/// app on iOS sees an empty `Platform.environment`, so simctl's
/// `SIMCTL_CHILD_*` variables can't carry it.) Without the file,
/// `--dart-define=PUX_SCENE=...` picks the scene, for `flutter run`.
void main() {
  runApp(ProviderScope(child: ScreenshotApp(sceneName: _sceneName())));
}

String _sceneName() {
  final file = File('${Directory.systemTemp.path}/pux_scene');
  if (file.existsSync()) {
    final name = file.readAsStringSync().trim();
    if (name.isNotEmpty) return name;
  }
  return const String.fromEnvironment(
    'PUX_SCENE',
    defaultValue: 'notification',
  );
}
