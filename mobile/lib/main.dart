import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:no_screenshot/no_screenshot.dart';

import 'src/app.dart';
import 'src/bootstrap.dart';
import 'src/services/delivery_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await NoScreenshot.instance.screenshotOff();
  } catch (error) {
    debugPrint('Screenshot protection unavailable: $error');
  }
  await bootstrap();
  runApp(const ProviderScope(child: PuxApp()));

  // Network work happens after the first frame so an offline device or a bad
  // Firebase config never leaves the app stuck on the splash screen. A macOS
  // app that starts in the menu bar may draw no frame until its window is
  // shown, so delivery starts after a moment without one.
  var started = false;
  void startDelivery() {
    if (started) return;
    started = true;
    unawaited(DeliveryController.instance.start());
  }

  WidgetsBinding.instance.addPostFrameCallback((_) => startDelivery());
  Timer(const Duration(seconds: 2), startDelivery);

  // Keeps the device registration fresh.
  AppLifecycleListener(
    onResume: () => unawaited(DeliveryController.instance.onResume()),
  );
}
