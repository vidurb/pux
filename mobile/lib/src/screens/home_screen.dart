import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/record_store.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _inbox;
  bool _showQr = false;
  String? _qrData;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final inbox = await RecordStore.instance.inbox();
    final payload = await RecordStore.instance.enrollmentPayload();
    setState(() {
      _inbox = inbox;
      _qrData = jsonEncode(payload);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('pux'),
        actions: [
          IconButton(
            tooltip: 'Add device',
            onPressed: () => setState(() => _showQr = !_showQr),
            icon: const Icon(Icons.qr_code),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Forward bank OTP emails to your inbox address. Codes arrive as encrypted push notifications.',
            ),
            const SizedBox(height: 16),
            if (_inbox != null) ...[
              const Text('Inbox address', style: TextStyle(fontWeight: FontWeight.bold)),
              SelectableText(_inbox!),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Clipboard.setData(ClipboardData(text: _inbox!)),
                child: const Text('Copy inbox address'),
              ),
            ],
            const SizedBox(height: 24),
            if (_showQr && _qrData != null) ...[
              const Text(
                'Scan to add another device',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Center(
                child: QrImageView(
                  data: _qrData!,
                  version: QrVersions.auto,
                  size: 220,
                ),
              ),
              const Text(
                'This QR contains your private key. Only show it to devices you trust.',
                style: TextStyle(color: Colors.orange),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
