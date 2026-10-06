import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app.dart';
import '../services/delivery_controller.dart';
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
    });

    try {
      final payload = RecordStore.instance.parseQr(_controller.text.trim());
      await RecordStore.instance.saveEnrollment(payload);
      unawaited(DeliveryController.instance.start());
      ref.invalidate(enrollmentProvider);

      if (!mounted) return;
      Navigator.of(
        context,
      ).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const HomeScreen()), (_) => false);
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
