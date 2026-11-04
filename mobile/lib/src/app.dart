import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/enroll_chooser_screen.dart';
import 'screens/home_screen.dart';
import 'services/record_store.dart';

final enrollmentProvider = FutureProvider<bool>(
  (ref) async {
    return RecordStore.instance.isEnrolled();
  },
  // Show a storage failure at once instead of Riverpod's default retries,
  // which would leave the app on its spinner for about 40 seconds.
  retry: (_, _) => null,
);

class PuxApp extends ConsumerWidget {
  const PuxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrollment = ref.watch(enrollmentProvider);

    return MaterialApp(
      title: 'pux',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0E3B32)),
        useMaterial3: true,
      ),
      home: enrollment.when(
        data: (enrolled) => enrolled ? const HomeScreen() : const EnrollChooserScreen(),
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (error, _) => Scaffold(body: Center(child: Text('Error: $error'))),
      ),
    );
  }
}
