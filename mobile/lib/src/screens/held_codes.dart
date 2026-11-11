import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/desktop_delivery_service.dart';
import '../services/sensitive_clipboard.dart';

/// Lists codes that may not have reached the user as a notification, so they can
/// be read while they're still valid. Shows nothing when there are none, which
/// is always on phones.
class HeldCodes extends StatelessWidget {
  const HeldCodes({required this.held, super.key});

  final ValueListenable<List<HeldDelivery>> held;

  @override
  Widget build(BuildContext context) {
    return _CodeList(
      deliveries: held,
      title: 'Codes that may not have appeared',
      explanation:
          "pux couldn't confirm these reached you as notifications. They "
          'are removed once they do, or when they expire, and are never '
          'saved on this device.',
    );
  }
}

/// Lists codes just shown as notifications, on desktops that can't report
/// whether a notification was displayed. Shows nothing when there are none,
/// which is always on phones and macOS.
class RecentCodes extends StatelessWidget {
  const RecentCodes({required this.recent, super.key});

  final ValueListenable<List<HeldDelivery>> recent;

  @override
  Widget build(BuildContext context) {
    return _CodeList(
      deliveries: recent,
      title: 'Recent codes',
      explanation:
          'Sent to you as notifications, and kept here in case your desktop '
          "didn't show them. They are removed when they expire, and are never "
          'saved on this device.',
    );
  }
}

class _CodeList extends StatelessWidget {
  const _CodeList({
    required this.deliveries,
    required this.title,
    required this.explanation,
  });

  final ValueListenable<List<HeldDelivery>> deliveries;
  final String title;
  final String explanation;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<HeldDelivery>>(
      valueListenable: deliveries,
      builder: (context, deliveries, _) {
        if (deliveries.isEmpty) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.primary),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 4),
                  Text(explanation),
                  for (final delivery in deliveries)
                    _HeldCode(
                      key: ValueKey(delivery.deliveryId),
                      delivery: delivery,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HeldCode extends StatelessWidget {
  const _HeldCode({required this.delivery, super.key});

  final HeldDelivery delivery;

  Future<void> _copy(BuildContext context, String code) async {
    await SensitiveClipboard.instance.copy(code);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Code copied. It is cleared from the clipboard in a minute.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notification = delivery.notification;
    final code = notification.code;

    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(notification.title),
                SelectableText(
                  notification.body,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          ),
          if (code != null)
            IconButton(
              tooltip: 'Copy code',
              onPressed: () => unawaited(_copy(context, code)),
              icon: const Icon(Icons.copy),
            ),
        ],
      ),
    );
  }
}
