import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app.dart';
import '../services/delivery_controller.dart';
import '../services/record_store.dart';
import 'enroll_chooser_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  String? _inbox;
  bool _showQr = false;
  String? _enrollmentJson;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final inbox = await RecordStore.instance.inbox();
    final payload = await RecordStore.instance.enrollmentPayload();
    if (!mounted) return;
    setState(() {
      _inbox = inbox;
      _enrollmentJson = jsonEncode(payload);
    });
  }

  Future<void> _copyEnrollmentJson() async {
    final json = _enrollmentJson;
    if (json == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Copy enrollment JSON?'),
        content: const Text(
          'This contains your private key and relay ID. Anyone who has it can '
          'read your OTP codes. Paste it only into your own desktop app, then '
          'clear your clipboard.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Copy')),
        ],
      ),
    );
    if (confirmed != true) return;

    await Clipboard.setData(ClipboardData(text: json));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Enrollment JSON copied')));
  }

  Future<void> _confirmReset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset this device?'),
        content: const Text(
          'This deletes the keys and relay from this device. Other enrolled '
          'devices keep working. You will need to create or import a relay again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _reset();
  }

  Future<void> _reset() async {
    await DeliveryController.instance.stop();
    await RecordStore.instance.clear();
    ref.invalidate(enrollmentProvider);
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const EnrollChooserScreen()),
      (_) => false,
    );
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
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'reset') _confirmReset();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'reset', child: Text('Reset this device')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ValueListenableBuilder<DeliveryStatus>(
            valueListenable: DeliveryController.instance.status,
            builder: (context, status, _) => _DeliveryBanner(status: status, onReset: _reset),
          ),
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
          if (_showQr && _enrollmentJson != null) ...[
            const Text('Add another device', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Center(
              child: QrImageView(
                data: _enrollmentJson!,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Scan this QR on another phone, or copy the enrollment JSON and '
              'paste it into the desktop app. Both contain your private key: '
              'only use them with devices you trust.',
              style: TextStyle(color: Colors.orange),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _copyEnrollmentJson,
              icon: const Icon(Icons.copy),
              label: const Text('Copy enrollment JSON'),
            ),
          ],
        ],
      ),
    );
  }
}

class _DeliveryBanner extends StatelessWidget {
  const _DeliveryBanner({required this.status, required this.onReset});

  final DeliveryStatus status;
  final Future<void> Function() onReset;

  @override
  Widget build(BuildContext context) {
    final undecryptable = status.undecryptable > 0
        ? '${status.undecryptable} message(s) could not be decrypted with this '
              "device's key."
        : null;

    final (Color color, String text, List<Widget> actions) = switch (status.state) {
      DeliveryState.idle || DeliveryState.ready => (Colors.orange, '', const <Widget>[]),
      DeliveryState.connecting => (Colors.blueGrey, 'Connecting…', const <Widget>[]),
      DeliveryState.retrying => (
        Colors.orange,
        'Not connected: ${status.message ?? 'unknown error'}',
        [
          TextButton(
            onPressed: () => unawaited(DeliveryController.instance.start()),
            child: const Text('Retry now'),
          ),
        ],
      ),
      DeliveryState.firebaseUnconfigured => (
        Colors.red,
        status.message ?? 'Push notifications are not configured in this build.',
        const <Widget>[],
      ),
      DeliveryState.recordUnknown => (
        Colors.red,
        'The server no longer knows this relay. It may have expired after a '
            'long period without use. Reset this device and create a new relay '
            '(then update your email forwarding).',
        [FilledButton(onPressed: onReset, child: const Text('Reset'))],
      ),
    };

    if (text.isEmpty && undecryptable == null) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (text.isNotEmpty) Text(text, style: TextStyle(color: color)),
              if (undecryptable != null)
                Text(undecryptable, style: const TextStyle(color: Colors.orange)),
              if (actions.isNotEmpty)
                Row(mainAxisAlignment: MainAxisAlignment.end, children: actions),
            ],
          ),
        ),
      ),
    );
  }
}
