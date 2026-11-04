import 'dart:async';

import 'package:flutter/material.dart';

import '../services/background_restrictions.dart';
import '../services/record_store.dart';

/// Asks the user to lift Android restrictions that stop codes from arriving.
///
/// The home screen is the first thing shown after setup, so this also covers
/// the first run. It rechecks whenever the app resumes, so a prompt goes away
/// as soon as the user changes the setting.
///
/// Dismissing a prompt silences that restriction until it has been lifted and
/// comes back, or until the relay is set up again: then it's a new problem, not
/// the one the user already chose to ignore.
class BackgroundRestrictionPrompts extends StatefulWidget {
  const BackgroundRestrictionPrompts({super.key});

  @override
  State<BackgroundRestrictionPrompts> createState() => _BackgroundRestrictionPromptsState();
}

class _BackgroundRestrictionPromptsState extends State<BackgroundRestrictionPrompts> {
  late final AppLifecycleListener _lifecycle;
  late final Future<Set<DeliveryRestriction>> _dismissed = _loadDismissed();
  Set<DeliveryRestriction> _active = const {};
  int _latestCheck = 0;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(_check()));
    unawaited(_check());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<Set<DeliveryRestriction>> _loadDismissed() async {
    try {
      final names = await RecordStore.instance.dismissedRestrictionPrompts();
      return DeliveryRestriction.values.where((r) => names.contains(r.name)).toSet();
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

  Future<void> _check() async {
    final check = ++_latestCheck;
    final dismissed = await _dismissed;
    final status = await BackgroundRestrictions.instance.check();
    if (!mounted || check != _latestCheck) return;

    if (dismissed.intersection(status.clear).isNotEmpty) {
      dismissed.removeAll(status.clear);
      unawaited(_saveDismissed(dismissed));
    }
    setState(() => _active = status.active.difference(dismissed));
  }

  Future<void> _dismiss(DeliveryRestriction restriction) async {
    final dismissed = await _dismissed;
    dismissed.add(restriction);
    if (mounted) setState(() => _active = _active.difference({restriction}));
    await _saveDismissed(dismissed);
  }

  Future<void> _openSettings(DeliveryRestriction restriction) async {
    final opened = await BackgroundRestrictions.instance.openSettings(restriction);
    if (opened || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Couldn't open settings. Open App info for pux from Settings.")),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final restriction in DeliveryRestriction.values)
          if (_active.contains(restriction))
            _Prompt(
              restriction: restriction,
              onDismiss: () => unawaited(_dismiss(restriction)),
              onOpenSettings: () => unawaited(_openSettings(restriction)),
            ),
      ],
    );
  }
}

class _Prompt extends StatelessWidget {
  const _Prompt({required this.restriction, required this.onDismiss, required this.onOpenSettings});

  final DeliveryRestriction restriction;
  final VoidCallback onDismiss;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
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
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.orange),
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
                  TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
                  FilledButton(onPressed: onOpenSettings, child: const Text('Open settings')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
