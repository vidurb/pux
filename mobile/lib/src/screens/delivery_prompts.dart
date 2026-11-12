import 'dart:async';

import 'package:flutter/material.dart';

import '../platform.dart';
import '../services/background_restrictions.dart';
import '../services/notification_permissions.dart';
import '../services/record_store.dart';
import 'notification_explainer.dart';

/// Asks the user to fix settings that stop codes from reaching them.
///
/// The home screen is the first thing shown after setup, so this also covers
/// the first run. That's also why this opens [NotificationExplainer] if the OS
/// has never asked about notifications. It rechecks whenever the app resumes,
/// so a prompt goes away as soon as the user changes the setting.
///
/// Only one prompt shows at a time, so the screen stays usable: notifications
/// first, because without them no code gets through, then the restrictions,
/// which wait until the one before is fixed or dismissed. Those that stop codes
/// arriving come before those that only let them arrive unnoticed.
///
/// Dismissing a restriction silences it until it has been lifted and comes back,
/// or until the relay is set up again: then it's a new problem, not the one the
/// user already chose to ignore. The same goes for the hints that codes would
/// arrive unnoticed, such as a quiet Android channel or the iOS scheduled
/// summary: the code still arrives, and the user may have chosen that.
///
/// While the OS has never asked ([NotificationAccess.notAsked], after "Not now"
/// on the explainer), the notification prompt's button asks, since settings
/// would have nothing to turn on yet.
///
/// The notification prompt can't be dismissed. A restriction is a risk to codes
/// in the future; this is a certainty now. On a phone the app has no other way to
/// show a code, and on a desktop codes wait on this screen and expire unseen, so
/// a dismissed prompt would only hide that the app has stopped working. It costs
/// little to keep: it shows only here, and nothing else on the screen is blocked.
class DeliveryPrompts extends StatefulWidget {
  const DeliveryPrompts({super.key});

  @override
  State<DeliveryPrompts> createState() => _DeliveryPromptsState();
}

class _DeliveryPromptsState extends State<DeliveryPrompts> {
  late final AppLifecycleListener _lifecycle;
  late final Future<Set<DeliveryRestriction>> _dismissed = _loadDismissed();
  DeliveryRestrictionStatus _background = const DeliveryRestrictionStatus();
  Set<DeliveryRestriction> _active = const {};
  int _latestCheck = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_check()));
    NotificationPermissions.instance.quietDelivery.addListener(
      _quietDeliveryChanged,
    );
    unawaited(_check());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(NotificationExplainer.showIfNeeded(context));
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    NotificationPermissions.instance.quietDelivery.removeListener(
      _quietDeliveryChanged,
    );
    super.dispose();
  }

  Future<Set<DeliveryRestriction>> _loadDismissed() async {
    try {
      final names = await RecordStore.instance.dismissedRestrictionPrompts();
      return DeliveryRestriction.values
          .where((r) => names.contains(r.name))
          .toSet();
    } catch (error) {
      debugPrint('Could not read dismissed prompts: $error');
      return {};
    }
  }

  Future<void> _saveDismissed(Set<DeliveryRestriction> dismissed) async {
    try {
      await RecordStore.instance.saveDismissedRestrictionPrompts(
        dismissed.map((r) => r.name).toSet(),
      );
    } catch (error) {
      debugPrint('Could not save dismissed prompts: $error');
    }
  }

  /// The notification check updates [NotificationPermissions.quietDelivery],
  /// which [_quietDeliveryChanged] picks up.
  Future<void> _check() async {
    final check = ++_latestCheck;
    unawaited(NotificationPermissions.instance.refresh());
    final dismissed = await _dismissed;
    final status = await BackgroundRestrictions.instance.check();
    if (!mounted || check != _latestCheck) return;

    _background = status;
    _update(dismissed);
  }

  void _quietDeliveryChanged() => unawaited(
    _dismissed.then((dismissed) {
      if (mounted) _update(dismissed);
    }),
  );

  void _update(Set<DeliveryRestriction> dismissed) {
    final quiet = NotificationPermissions.instance.quietDelivery.value;
    final clear = {..._background.clear, ...quiet.clear};
    if (dismissed.intersection(clear).isNotEmpty) {
      dismissed.removeAll(clear);
      unawaited(_saveDismissed(dismissed));
    }
    setState(
      () => _active = {
        ..._background.active,
        ...quiet.active,
      }.difference(dismissed),
    );
  }

  Future<void> _dismiss(DeliveryRestriction restriction) async {
    final dismissed = await _dismissed;
    dismissed.add(restriction);
    if (mounted) setState(() => _active = _active.difference({restriction}));
    await _saveDismissed(dismissed);
  }

  Future<void> _openSettings(
    Future<bool> Function() open, {
    required String fallback,
  }) async {
    final opened = await open();
    if (opened || !mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(fallback)));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<NotificationAccess>(
      valueListenable: NotificationPermissions.instance.access,
      builder: (context, access, _) {
        if (access != NotificationAccess.allowed) {
          return _notificationPrompt(access);
        }

        for (final restriction in DeliveryRestriction.values) {
          if (_active.contains(restriction)) {
            return _restrictionPrompt(restriction);
          }
        }
        return const SizedBox.shrink();
      },
    );
  }

  Widget _notificationPrompt(NotificationAccess access) {
    const lost = 'Codes that arrive in the meantime are lost.';
    final (String title, String body) = switch (access) {
      NotificationAccess.notAsked when isDesktopPlatform => (
        'Notifications are off',
        'New codes wait on this screen until you allow notifications, or until '
            'they expire, up to 15 minutes after arriving.',
      ),
      NotificationAccess.notAsked => (
        'Notifications are off',
        "pux can only show codes as notifications, so you won't see any until "
            'you allow them. $lost',
      ),
      NotificationAccess.channelOff => (
        'OTP code notifications are off',
        'The "OTP codes" notification category is turned off for pux, so you '
            "won't see any codes. $lost Open settings and turn it on.",
      ),
      NotificationAccess.quiet => (
        'Codes may arrive without an alert',
        "pux's notifications are set to arrive quietly, with no banner or alert, "
            'so you could miss a code before it expires. Open settings and turn '
            'on alerts for pux.',
      ),
      _ when isDesktopPlatform => (
        'Notifications are off',
        "New codes wait on this screen until you allow notifications, or until "
            'they expire, up to 15 minutes after arriving. Open settings and '
            'allow notifications for pux.',
      ),
      _ => (
        'Notifications are off',
        "pux can only show codes as notifications, so you won't see any until "
            'you allow them. $lost Open settings and allow notifications for pux.',
      ),
    };

    if (access == NotificationAccess.notAsked) {
      return _Prompt(
        title: title,
        body: body,
        color: Colors.red,
        actionLabel: 'Allow notifications',
        onAction: () => unawaited(NotificationPermissions.instance.ask()),
      );
    }

    return _Prompt(
      title: title,
      body: body,
      color: access == NotificationAccess.quiet ? Colors.orange : Colors.red,
      onAction: () => unawaited(
        _openSettings(
          NotificationPermissions.instance.openSettings,
          fallback:
              "Couldn't open settings. Find pux in your device's settings and "
              'allow notifications.',
        ),
      ),
    );
  }

  Widget _restrictionPrompt(DeliveryRestriction restriction) {
    final (String title, String body) = switch (restriction) {
      DeliveryRestriction.hibernation => (
        'Keep codes arriving when you rarely open pux',
        "If pux goes a few months without being opened, Android pauses it and "
            "codes stop arriving until you open it again. Reading a notification "
            "doesn't count as opening it. In App info, turn off \"Pause app "
            'activity if unused" (on Android 12, "Remove permissions and free up '
            'space").',
      ),
      DeliveryRestriction.backgroundUse => (
        'Background use is restricted',
        "Android is restricting pux's battery use, so codes may not arrive. "
            'In App info, open the battery or app battery usage page and allow '
            'background use.',
      ),
      DeliveryRestriction.quietChannel => (
        "Codes don't pop up on screen",
        'The "OTP codes" notification category is set not to pop up on '
            'screen, so you could miss a code before it expires. Open settings '
            'and let it make a sound and pop up on screen.',
      ),
      DeliveryRestriction.scheduledSummary => (
        'Codes wait for your notification summary',
        "iOS holds pux's notifications for your scheduled summary, so codes "
            'can expire before you see them. Open settings and choose Immediate '
            'Delivery for pux.',
      ),
    };

    final (
      Future<bool> Function() open,
      String fallback,
    ) = switch (restriction) {
      DeliveryRestriction.hibernation || DeliveryRestriction.backgroundUse => (
        () => BackgroundRestrictions.instance.openSettings(restriction),
        "Couldn't open settings. Open App info for pux from Settings.",
      ),
      DeliveryRestriction.quietChannel ||
      DeliveryRestriction.scheduledSummary => (
        NotificationPermissions.instance.openQuietDeliverySettings,
        "Couldn't open settings. Find pux in your device's notification settings.",
      ),
    };

    return _Prompt(
      title: title,
      body: body,
      color: Colors.orange,
      onDismiss: () => unawaited(_dismiss(restriction)),
      onAction: () => unawaited(_openSettings(open, fallback: fallback)),
    );
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({
    required this.title,
    required this.body,
    required this.color,
    required this.onAction,
    this.actionLabel = 'Open settings',
    this.onDismiss,
  });

  final String title;
  final String body;
  final Color color;
  final VoidCallback onAction;
  final String actionLabel;

  /// Null if this prompt can't be dismissed.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
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
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(body),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (onDismiss != null)
                    TextButton(
                      onPressed: onDismiss,
                      child: const Text('Dismiss'),
                    ),
                  FilledButton(onPressed: onAction, child: Text(actionLabel)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
