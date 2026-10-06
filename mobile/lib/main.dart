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
  // Firebase config never leaves the app stuck on the splash screen.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(DeliveryController.instance.start());
  });
}
