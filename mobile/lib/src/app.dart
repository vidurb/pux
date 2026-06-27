import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/enroll_screen.dart';
import 'screens/home_screen.dart';
import 'services/record_store.dart';

final enrollmentProvider = FutureProvider<bool>((ref) async {
  return RecordStore.instance.isEnrolled();
});

class PuxApp extends ConsumerWidget {
  const PuxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enrollment = ref.watch(enrollmentProvider);

    return MaterialApp(
      title: 'pux',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F6FEB)),
        useMaterial3: true,
      ),
      home: enrollment.when(
        data: (enrolled) => enrolled ? const HomeScreen() : const EnrollScreen(),
        loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
        error: (error, _) => Scaffold(body: Center(child: Text('Error: $error'))),
      ),
    );
  }
}
