import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app.dart';
import '../services/push_service.dart';
import '../services/record_store.dart';
import 'home_screen.dart';

class EnrollScreen extends ConsumerStatefulWidget {
  const EnrollScreen({super.key});

  @override
  ConsumerState<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends ConsumerState<EnrollScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _processing = false;
  bool _enrolled = false;
  String? _error;
  String? _pushWarning;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _handleQr(String raw) async {
    if (_processing || _enrolled) return;
    setState(() {
      _processing = true;
      _error = null;
      _pushWarning = null;
    });

    try {
      final payload = RecordStore.instance.parseQr(raw);
      await RecordStore.instance.saveEnrollment(payload);

      final server = payload['server'] as String?;
      if (server != null) {
        RecordStore.instance.serverUrl = server;
      }

      String? pushWarning;
      try {
        await PushService.instance.init();
      } catch (error) {
        pushWarning = 'Enrolled, but push registration failed: $error';
      }

      await _scannerController.stop();
      ref.invalidate(enrollmentProvider);

      if (!mounted) return;
      setState(() {
        _enrolled = true;
        _pushWarning = pushWarning;
      });

      if (pushWarning == null) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => const HomeScreen()),
        );
      }
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
              controller: _scannerController,
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
          if (_pushWarning != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(_pushWarning!, style: const TextStyle(color: Colors.orange)),
            ),
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
