import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/record_store.dart';
import 'confirm_server_dialog.dart';
import 'enrollment_commit.dart';

class ImportEnrollmentScreen extends ConsumerStatefulWidget {
  const ImportEnrollmentScreen({super.key});

  @override
  ConsumerState<ImportEnrollmentScreen> createState() => _ImportEnrollmentScreenState();
}

class _ImportEnrollmentScreenState extends ConsumerState<ImportEnrollmentScreen>
    with EnrollmentCommit<ImportEnrollmentScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _processing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _importEnrollment() async {
    if (_processing) return;

    setState(() {
      _processing = true;
      enrollmentError = null;
    });

    try {
      final payload = RecordStore.instance.parseQr(_controller.text.trim());
      final server = RecordStore.instance.enrollmentServer(payload);
      if (!mounted || !await confirmEnrollmentServer(context, server)) return;
      if (!mounted) return;
      await commitEnrollment(() => RecordStore.instance.saveEnrollment(payload));
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
        appBar: AppBar(
          title: const Text('Import enrollment'),
          automaticallyImplyLeading: !committing,
        ),
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
              if (enrollmentError != null) ...[
                const SizedBox(height: 16),
                Text(enrollmentError!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
