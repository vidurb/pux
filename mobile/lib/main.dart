import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:no_screenshot/no_screenshot.dart';

import 'src/app.dart';
import 'src/bootstrap.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NoScreenshot.instance.screenshotOff();
  await bootstrap();
  runApp(const ProviderScope(child: PuxApp()));
}
