import 'package:flutter/material.dart';

/// Shows which server an imported or scanned enrollment points at, so a
/// tampered payload cannot silently send this device's traffic elsewhere.
Future<bool> confirmEnrollmentServer(BuildContext context, String server) async {
  final uri = Uri.parse(server);
  final host = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;

  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Connect to this server?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This enrollment uses the pux server'),
          const SizedBox(height: 8),
          SelectableText(host, style: const TextStyle(fontWeight: FontWeight.bold)),
          if (uri.scheme == 'http') ...[
            const SizedBox(height: 8),
            const Text(
              'Unencrypted connection (local development only).',
              style: TextStyle(color: Colors.orange),
            ),
          ],
          const SizedBox(height: 8),
          const Text('Only continue if you recognise this server.'),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
