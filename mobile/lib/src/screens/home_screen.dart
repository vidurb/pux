import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../app.dart';
import '../services/api_client.dart';
import '../services/delivery_controller.dart';
import '../services/record_store.dart';
import '../services/sensitive_clipboard.dart';
import 'delivery_prompts.dart';
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
  bool _removing = false;

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

    await SensitiveClipboard.instance.copy(json);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Enrollment JSON copied. It is cleared from the clipboard in a minute.'),
      ),
    );
  }

  Future<void> _confirmRemoveDevice() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove this device?'),
        content: const Text(
          'This device stops receiving codes and its keys are deleted from it. '
          'Other devices on this relay keep working. To use pux here again you '
          'will need to create or import a relay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await _removeWith(
      failureTitle: "Couldn't remove this device from the server",
      forgetWarning:
          'If you forget it locally, the server keeps this registration until '
          'it expires, which can take up to 2 years.',
      serverCall: () async {
        final recordId = await RecordStore.instance.recordId();
        final deviceId = await RecordStore.instance.deviceId();
        // Never registered with a server that returns device IDs: nothing to remove.
        if (recordId == null || deviceId == null) return;
        await ApiClient.instance.deleteDevice(recordId: recordId, deviceId: deviceId);
      },
    );
  }

  Future<void> _confirmDeleteRelay() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => const _DeleteRelayDialog(),
    );
    if (confirmed != true) return;

    await _removeWith(
      failureTitle: "Couldn't delete the relay",
      forgetWarning:
          'If you forget it locally, the relay keeps running on the server and '
          'your other devices keep receiving codes.',
      serverCall: () async {
        final recordId = await RecordStore.instance.recordId();
        if (recordId == null) return;
        await ApiClient.instance.deleteRecord(recordId: recordId);
      },
    );
  }

  /// Stops delivery, runs [serverCall], then forgets the relay locally. If
  /// the server call fails the user can retry, cancel (delivery restarts) or
  /// forget locally anyway.
  Future<void> _removeWith({
    required String failureTitle,
    required String forgetWarning,
    required Future<void> Function() serverCall,
  }) async {
    setState(() => _removing = true);
    await DeliveryController.instance.stop();

    while (true) {
      try {
        await serverCall();
        break;
      } catch (error) {
        if (!mounted) return;
        final choice = await showDialog<_RemovalFailureChoice>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(failureTitle),
            content: Text('The server could not be reached or refused: $error\n\n$forgetWarning'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(_RemovalFailureChoice.cancel),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(_RemovalFailureChoice.retry),
                child: const Text('Try again'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(_RemovalFailureChoice.forget),
                child: const Text('Forget locally anyway'),
              ),
            ],
          ),
        );
        if (choice == _RemovalFailureChoice.retry) continue;
        if (choice == _RemovalFailureChoice.forget) break;

        if (mounted) setState(() => _removing = false);
        unawaited(DeliveryController.instance.start());
        return;
      }
    }

    await _forgetLocally();
  }

  Future<void> _forgetLocally() async {
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
            enabled: !_removing,
            onSelected: (value) {
              switch (value) {
                case 'remove_device':
                  _confirmRemoveDevice();
                case 'delete_relay':
                  _confirmDeleteRelay();
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'remove_device', child: Text('Remove this device')),
              PopupMenuItem(value: 'delete_relay', child: Text('Delete relay everywhere')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_removing) const LinearProgressIndicator(),
          const DeliveryPrompts(),
          ValueListenableBuilder<DeliveryStatus>(
            valueListenable: DeliveryController.instance.status,
            builder: (context, status, _) =>
                _DeliveryBanner(status: status, onForget: _forgetLocally),
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
  const _DeliveryBanner({required this.status, required this.onForget});

  final DeliveryStatus status;
  final Future<void> Function() onForget;

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
        'The server no longer knows this relay. It may have expired after going '
            'a long time with no registered devices. Forget it on this device and '
            'create a new relay (then update your email forwarding).',
        [FilledButton(onPressed: onForget, child: const Text('Forget relay'))],
      ),
      DeliveryState.tooManyDevices => (
        Colors.red,
        'This relay already has the maximum number of devices. On a device you '
            'no longer use, choose "Remove this device", then retry here.',
        [
          TextButton(
            onPressed: () => unawaited(DeliveryController.instance.start()),
            child: const Text('Retry'),
          ),
        ],
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

enum _RemovalFailureChoice { cancel, retry, forget }

/// Deleting the relay stops every device and the inbox address, so it asks
/// the user to type a word rather than tap once.
class _DeleteRelayDialog extends StatefulWidget {
  const _DeleteRelayDialog();

  static const confirmationWord = 'delete';

  @override
  State<_DeleteRelayDialog> createState() => _DeleteRelayDialogState();
}

class _DeleteRelayDialogState extends State<_DeleteRelayDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final confirmed = _controller.text.trim().toLowerCase() == _DeleteRelayDialog.confirmationWord;

    return AlertDialog(
      title: const Text('Delete relay everywhere?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This deletes the relay from the server. Every device on it stops '
            'receiving codes, the inbox address stops working and pending codes '
            'are discarded. This cannot be undone.',
          ),
          const SizedBox(height: 16),
          const Text('Type "${_DeleteRelayDialog.confirmationWord}" to confirm.'),
          TextField(
            controller: _controller,
            autofocus: true,
            autocorrect: false,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
          onPressed: confirmed ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Delete everywhere'),
        ),
      ],
    );
  }
}
