import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../services/api_client.dart';
import '../services/crypto_service.dart';
import '../services/delivery_runtime.dart';
import '../services/record_store.dart';
import 'home_screen.dart';

class CreateRelayScreen extends ConsumerStatefulWidget {
  const CreateRelayScreen({super.key});

  @override
  ConsumerState<CreateRelayScreen> createState() => _CreateRelayScreenState();
}

class _CreateRelayScreenState extends ConsumerState<CreateRelayScreen> {
  bool _processing = false;
  String? _error;
  String? _pushWarning;

  Future<void> _createRelay() async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
      _pushWarning = null;
    });

    try {
      final keys = await CryptoService.instance.generateKeyPair();
      final record = await ApiClient.instance.createRecord(
        publicKey: keys['public_key']!,
      );

      await RecordStore.instance.saveEnrollment({
        'record_id': record['record_id'],
        'private_key': keys['private_key'],
        'public_key': keys['public_key'],
        'inbox': record['inbox_address'],
        'server': RecordStore.instance.serverUrl,
      });

      String? pushWarning;
      try {
        await deliveryServiceForPlatform().init();
      } catch (error) {
        pushWarning = 'Relay created, but push registration failed: $error';
      }

      ref.invalidate(enrollmentProvider);

      if (!mounted) return;
      setState(() => _pushWarning = pushWarning);

      if (pushWarning == null) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
          (_) => false,
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create relay')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'A new encryption keypair will be generated on this device. '
              'Only the public key is sent to the server.',
            ),
            const SizedBox(height: 24),
            if (_processing) const LinearProgressIndicator(),
            if (_pushWarning != null) ...[
              const SizedBox(height: 16),
              Text(_pushWarning!, style: const TextStyle(color: Colors.orange)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const HomeScreen()),
                    (_) => false,
                  );
                },
                child: const Text('Continue'),
              ),
            ] else
              FilledButton(
                onPressed: _processing ? null : _createRelay,
                child: const Text('Generate keys and create relay'),
              ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
    );
  }
}
