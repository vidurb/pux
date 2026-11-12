import 'dart:async';

import 'package:flutter/material.dart';

import '../platform.dart';
import '../services/notification_permissions.dart';
import '../services/record_store.dart';

/// Says why pux needs notifications, then lets the OS ask.
///
/// Nothing asks for notification permission at startup any more, so the system
/// prompt never appears without this first. It opens by itself over the home
/// screen, so right after setting up, and on the first launch of a build that
/// no longer asks at startup, but only while the OS has never asked
/// ([NotificationAccess.notAsked]). That's never on Linux or Windows, which
/// have no permission, nor once the user has answered: a denial is the home
/// screen's "Notifications are off" prompt, which only settings can fix.
///
/// "Not now" leaves the OS unasked, and stops this opening by itself until the
/// relay is set up again. The home screen's prompt still says notifications are
/// off, and its button asks then.
class NotificationExplainer extends StatefulWidget {
  const NotificationExplainer({super.key});

  /// Opens the explainer if the OS has never asked and the user hasn't chosen
  /// "Not now". Returns once it has closed, or at once if it didn't open.
  /// Never throws.
  static Future<void> showIfNeeded(BuildContext context) async {
    try {
      final navigator = Navigator.of(context);
      if (await _skipped()) return;
      // No timeout: an OS that never answers just means no explainer.
      final access = await NotificationPermissions.instance.check();
      if (access != NotificationAccess.notAsked || !context.mounted) return;

      final continued = await navigator.push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => const NotificationExplainer(),
        ),
      );
      // Closed any other way than Continue, such as the back button.
      if (continued != true) await _saveSkipped();
    } catch (error) {
      debugPrint('Could not show the notification explainer: $error');
    }
  }

  static Future<bool> _skipped() async {
    try {
      return await RecordStore.instance.notificationExplainerSkipped();
    } catch (error) {
      debugPrint('Could not read whether the explainer was skipped: $error');
      return false;
    }
  }

  static Future<void> _saveSkipped() async {
    try {
      await RecordStore.instance.saveNotificationExplainerSkipped();
    } catch (error) {
      debugPrint('Could not save that the explainer was skipped: $error');
    }
  }

  @override
  State<NotificationExplainer> createState() => _NotificationExplainerState();
}

class _NotificationExplainerState extends State<NotificationExplainer> {
  bool _asking = false;

  Future<void> _continue() async {
    setState(() => _asking = true);
    await NotificationPermissions.instance.ask();
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final why = isDesktopPlatform
        ? 'When a code arrives, pux shows it as a notification. Without '
              'notifications, new codes wait on the home screen until they '
              'expire, up to 15 minutes after arriving.'
        : 'Codes sent to your inbox address reach this device only as '
              "notifications. Without them, pux can't show you a code.";

    return PopScope(
      canPop: !_asking,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Notifications'),
          automaticallyImplyLeading: false,
        ),
        // The buttons stay in view however short the window; the text scrolls.
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                      children: [
                        const Icon(
                          Icons.notifications_active_outlined,
                          size: 64,
                        ),
                        const SizedBox(height: 24),
                        Text(
                          'Allow notifications to see your codes',
                          style: Theme.of(context).textTheme.titleLarge,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        Text(why),
                        const SizedBox(height: 12),
                        const Text(
                          'pux notifies you only when a code or a forwarding '
                          'confirmation arrives. Nothing else is sent.',
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'After you continue, your device asks whether to '
                          'allow notifications from pux.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_asking) const LinearProgressIndicator(),
                        FilledButton(
                          onPressed: _asking ? null : _continue,
                          child: const Text('Continue'),
                        ),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _asking
                              ? null
                              : () => Navigator.of(context).pop(false),
                          child: const Text('Not now'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
