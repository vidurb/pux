import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform.dart';
import 'create_relay_screen.dart';
import 'enroll_screen.dart';
import 'import_enrollment_screen.dart';

class EnrollChooserScreen extends ConsumerWidget {
  const EnrollChooserScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = isDesktopPlatform;

    return Scaffold(
      appBar: AppBar(title: const Text('Set up pux')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isDesktop
                  ? 'Import an existing relay to receive OTP codes on this computer.'
                  : 'Create a new encrypted OTP relay, or add this device to an existing one.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            if (!isDesktop) ...[
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
            ] else
              FilledButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ImportEnrollmentScreen()),
                  );
                },
                child: const Text('Import enrollment'),
              ),
            const SizedBox(height: 24),
            Text(
              isDesktop
                  ? 'Key generation happens on mobile. Desktop clients only receive decrypted codes.'
                  : 'Keys are generated on your device. The private key never leaves your phone.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
