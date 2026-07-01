import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../services/delivery_runtime.dart';
import '../services/record_store.dart';
import 'home_screen.dart';

class ImportEnrollmentScreen extends ConsumerStatefulWidget {
  const ImportEnrollmentScreen({super.key});

  @override
  ConsumerState<ImportEnrollmentScreen> createState() => _ImportEnrollmentScreenState();
}

class _ImportEnrollmentScreenState extends ConsumerState<ImportEnrollmentScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _processing = false;
  String? _error;
  String? _deliveryWarning;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _importEnrollment() async {
    if (_processing) return;

    setState(() {
      _processing = true;
      _error = null;
      _deliveryWarning = null;
    });

    try {
      final payload = RecordStore.instance.parseQr(_controller.text.trim());
      await RecordStore.instance.saveEnrollment(payload);

      final server = payload['server'] as String?;
      if (server != null) {
        RecordStore.instance.serverUrl = server;
      }

      String? deliveryWarning;
      try {
        await deliveryServiceForPlatform().init();
      } catch (error) {
        deliveryWarning = 'Enrolled, but delivery registration failed: $error';
      }

      ref.invalidate(enrollmentProvider);

      if (!mounted) return;
      setState(() => _deliveryWarning = deliveryWarning);

      if (deliveryWarning == null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
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
      appBar: AppBar(title: const Text('Import enrollment')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Paste the enrollment JSON exported from a mobile device. '
              'Desktop clients receive OTP codes but do not generate keys.',
            ),
            const SizedBox(height: 16),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: '{"v":1,"record_id":"...","private_key":"..."}',
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_processing) const LinearProgressIndicator(),
            if (_deliveryWarning != null) ...[
              const SizedBox(height: 16),
              Text(_deliveryWarning!, style: const TextStyle(color: Colors.orange)),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  Navigator.of(context).pushReplacement(
                    MaterialPageRoute(builder: (_) => const HomeScreen()),
                  );
                },
                child: const Text('Continue'),
              ),
            ] else
              FilledButton(
                onPressed: _processing ? null : _importEnrollment,
                child: const Text('Import and connect'),
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
