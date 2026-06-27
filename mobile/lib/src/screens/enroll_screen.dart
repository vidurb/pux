import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/push_service.dart';
import '../services/record_store.dart';
import 'home_screen.dart';

class EnrollScreen extends StatefulWidget {
  const EnrollScreen({super.key});

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  bool _processing = false;
  String? _error;

  Future<void> _handleQr(String raw) async {
    if (_processing) return;
    setState(() {
      _processing = true;
      _error = null;
    });

    try {
      final payload = RecordStore.instance.parseQr(raw);
      await RecordStore.instance.saveEnrollment(payload);

      final recordId = payload['record_id'] as String;
      final server = payload['server'] as String?;
      if (server != null) {
        RecordStore.instance.serverUrl = server;
      }

      try {
        await PushService.instance.init();
      } catch (_) {
        // FCM may be unavailable in dev builds without google-services.json
      }

      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => const HomeScreen()),
      );
    } catch (error) {
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enroll device')),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Scan the signup QR from the pux web page, or from an existing device.',
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(
            child: MobileScanner(
              onDetect: (capture) {
                final barcodes = capture.barcodes;
                for (final barcode in barcodes) {
                  final raw = barcode.rawValue;
                  if (raw != null) {
                    _handleQr(raw);
                    break;
                  }
                }
              },
            ),
          ),
          if (_processing) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
        ],
      ),
    );
  }
}
