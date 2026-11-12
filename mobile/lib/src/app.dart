import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/desktop_settings_screen.dart';
import 'screens/enroll_chooser_screen.dart';
import 'screens/home_screen.dart';
import 'services/desktop_shell.dart';
import 'services/record_store.dart';
import 'theme.dart';

final enrollmentProvider = FutureProvider<bool>(
  (ref) async {
    return RecordStore.instance.isEnrolled();
  },
  // Show a storage failure at once instead of Riverpod's default retries,
  // which would leave the app on its spinner for about 40 seconds.
  retry: (_, _) => null,
);

final _navigatorKey = GlobalKey<NavigatorState>();

/// Opens the desktop settings from the menu bar, unless they are open already.
void openDesktopSettings() {
  final navigator = _navigatorKey.currentState;
  if (navigator == null || DesktopSettingsScreen.isOpen) return;
  navigator.push(
    MaterialPageRoute<void>(builder: (_) => const DesktopSettingsScreen()),
  );
}

class PuxApp extends ConsumerStatefulWidget {
  const PuxApp({super.key});

  @override
  ConsumerState<PuxApp> createState() => _PuxAppState();
}

class _PuxAppState extends ConsumerState<PuxApp> {
  @override
  void initState() {
    super.initState();
    DesktopShell.instance.listen(onOpenSettings: openDesktopSettings);
  }

  @override
  Widget build(BuildContext context) {
    final enrollment = ref.watch(enrollmentProvider);

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'pux',
      theme: puxTheme(),
      home: enrollment.when(
        data: (enrolled) =>
            enrolled ? const HomeScreen() : const EnrollChooserScreen(),
        loading: () =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (error, _) =>
            Scaffold(body: Center(child: Text('Error: $error'))),
      ),
    );
  }
}
