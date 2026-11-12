import 'package:flutter/material.dart';

import '../platform.dart';
import '../services/api_client.dart';
import '../services/record_store.dart';

/// "Send a test code": asks the server to push a made-up code to every device
/// on the relay, then says which code to look for and where. Also points at
/// the mail leg, which this doesn't cover: emailing the inbox address.
class SendTestCodeButton extends StatefulWidget {
  const SendTestCodeButton({required this.inbox, super.key});

  /// The relay's inbox address, for the end-to-end email check.
  final String inbox;

  /// What the user can email to [inbox] to check forwarding, as in README.md.
  static const testEmail = 'Your OTP is 123456';

  @override
  State<SendTestCodeButton> createState() => _SendTestCodeButtonState();
}

class _SendTestCodeButtonState extends State<SendTestCodeButton> {
  bool _sending = false;

  Future<void> _send() async {
    setState(() => _sending = true);
    final TestCode sent;
    try {
      final recordId = await RecordStore.instance.recordId();
      if (recordId == null) throw const RecordNotFoundException();
      sent = await ApiClient.instance.sendTestCode(recordId: recordId);
    } catch (error) {
      if (!mounted) return;
      setState(() => _sending = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_failure(error))));
      return;
    }
    if (!mounted) return;
    setState(() => _sending = false);
    await showDialog<void>(
      context: context,
      builder: (context) => _SentDialog(sent: sent, inbox: widget.inbox),
    );
  }

  static String _failure(Object error) => switch (error) {
    RateLimitedException() =>
      'Too many test codes for now. Wait a minute, then try again.',
    NoDevicesException() =>
      'No device is registered on this relay yet. Wait until this device '
          'has connected, then try again.',
    RecordNotFoundException() => 'The server no longer knows this relay.',
    _ => "Couldn't send a test code: $error",
  };

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: _sending ? null : _send,
      icon: _sending
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.send_outlined),
      label: const Text('Send a test code'),
    );
  }
}

class _SentDialog extends StatelessWidget {
  const _SentDialog({required this.sent, required this.inbox});

  final TestCode sent;
  final String inbox;

  @override
  Widget build(BuildContext context) {
    final where = isDesktopPlatform
        ? 'Here it appears as a notification. If pux can\'t tell whether '
              'the notification showed, the code is also listed on this '
              'screen for a few minutes.'
        : 'On this phone it arrives as a notification within a few seconds.';
    final others = sent.devices > 1
        ? ' It went to all ${sent.devices} devices on this relay.'
        : '';

    return AlertDialog(
      title: const Text('Test code sent'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Look for "OTP from pux test" with the code'),
            const SizedBox(height: 8),
            SelectableText(
              sent.otp,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 8),
            Text('$where$others'),
            const SizedBox(height: 16),
            Text(
              'This checks the server and push. To check that mail reaches '
              'the relay too, email "${SendTestCodeButton.testEmail}" '
              'straight to $inbox. It should arrive the same way, with '
              '123456 as the code.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
