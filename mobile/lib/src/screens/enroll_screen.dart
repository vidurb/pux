import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/record_store.dart';
import 'confirm_server_dialog.dart';
import 'enrollment_commit.dart';

class EnrollScreen extends ConsumerStatefulWidget {
  const EnrollScreen({super.key});

  @override
  ConsumerState<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends ConsumerState<EnrollScreen> with EnrollmentCommit<EnrollScreen> {
  final MobileScannerController _scannerController = MobileScannerController();
  bool _processing = false;
  bool _enrolled = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _handleQr(String raw) async {
    if (_processing || _enrolled) return;
    setState(() {
      _processing = true;
      enrollmentError = null;
    });

    try {
      final payload = RecordStore.instance.parseQr(raw);
      final server = RecordStore.instance.enrollmentServer(payload);
      await _scannerController.stop();
      if (!mounted) return;
      if (!await confirmEnrollmentServer(context, server)) {
        await _scannerController.start();
        return;
      }
      if (!mounted) return;
      _enrolled = await commitEnrollment(() => RecordStore.instance.saveEnrollment(payload));
      // Back to scanning, so a failed save can be retried from this screen.
      if (!_enrolled && mounted) await _scannerController.start();
    } catch (error) {
      if (mounted) setState(() => enrollmentError = error.toString());
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return enrollmentPopScope(
      child: Scaffold(
        appBar: AppBar(title: const Text('Enroll device'), automaticallyImplyLeading: !committing),
        body: Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Scan the QR from an existing enrolled device.',
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
            if (enrollmentError != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(enrollmentError!, style: const TextStyle(color: Colors.red)),
              ),
          ],
        ),
      ),
    );
  }
}
