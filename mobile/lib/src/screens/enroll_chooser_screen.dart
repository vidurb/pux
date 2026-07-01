import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'create_relay_screen.dart';
import 'enroll_screen.dart';

class EnrollChooserScreen extends ConsumerWidget {
  const EnrollChooserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set up pux')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Create a new encrypted OTP relay, or add this device to an existing one.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CreateRelayScreen()),
                );
              },
              child: const Text('Create new relay'),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const EnrollScreen()),
                );
              },
              child: const Text('Add to existing relay'),
            ),
            const SizedBox(height: 24),
            const Text(
              'Keys are generated on your device. The private key never leaves your phone.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
