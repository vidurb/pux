import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/desktop_shell.dart';

/// How pux runs on the desktop: in the menu bar, at login, and what closing
/// the window does.
class DesktopSettingsScreen extends StatefulWidget {
  const DesktopSettingsScreen({super.key});

  static int _open = 0;

  /// Whether the screen is on the navigation stack.
  static bool get isOpen => _open > 0;

  @override
  State<DesktopSettingsScreen> createState() => _DesktopSettingsScreenState();
}

class _DesktopSettingsScreenState extends State<DesktopSettingsScreen>
    with WidgetsBindingObserver {
  final _shell = DesktopShell.instance;

  DesktopSettings? _settings;
  Object? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    DesktopSettingsScreen._open++;
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    DesktopSettingsScreen._open--;
    super.dispose();
  }

  /// The login item can change in System Settings, so read it again on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _shell.load();
      if (!mounted) return;
      setState(() {
        _settings = settings;
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _update(Future<DesktopSettings> Function() change) async {
    setState(() => _saving = true);
    try {
      final settings = await change();
      if (!mounted) return;
      setState(() => _settings = settings);
    } on PlatformException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("Couldn't change the setting: ${error.message}"),
        ),
      );
      await _load();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    return Scaffold(
      appBar: AppBar(title: const Text('Desktop settings')),
      body: switch ((settings, _loadError)) {
        (_, final Object error) => Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text("Couldn't read the settings: $error"),
          ),
        ),
        (null, _) => const Center(child: CircularProgressIndicator()),
        (final DesktopSettings settings, _) => _list(settings),
      },
    );
  }

  Widget _list(DesktopSettings settings) {
    final login = settings.launchAtLogin;
    return ListView(
      children: [
        if (_saving) const LinearProgressIndicator(),
        SwitchListTile(
          title: const Text('Open at login'),
          subtitle: Text(switch (login) {
            LaunchAtLogin.unsupported => 'Needs macOS 13 or later.',
            LaunchAtLogin.requiresApproval =>
              'Waiting for you to allow pux in System Settings → General → '
                  'Login Items.',
            _ =>
              'Start pux when you log in, so codes arrive without opening it.',
          }),
          value:
              login == LaunchAtLogin.enabled ||
              login == LaunchAtLogin.requiresApproval,
          onChanged: _saving || login == LaunchAtLogin.unsupported
              ? null
              : (value) => _update(() => _shell.setLaunchAtLogin(value)),
        ),
        if (login == LaunchAtLogin.requiresApproval)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _shell.openLoginItemsSettings,
                child: const Text('Open Login Items'),
              ),
            ),
          ),
        SwitchListTile(
          title: const Text('Start in the menu bar'),
          subtitle: const Text(
            'Open without a window. Click the pux icon in the menu bar to '
            'show it.',
          ),
          value: settings.startHidden,
          onChanged: _saving
              ? null
              : (value) => _update(() => _shell.setStartHidden(value)),
        ),
        SwitchListTile(
          title: const Text('Quit when the window is closed'),
          subtitle: Text(
            settings.closeQuits
                ? 'Closing the window quits pux, and codes stop arriving '
                      'until you open it again.'
                : 'Closing the window keeps pux in the menu bar, so codes '
                      'keep arriving.',
          ),
          value: settings.closeQuits,
          onChanged: _saving
              ? null
              : (value) => _update(() => _shell.setCloseQuits(value)),
        ),
      ],
    );
  }
}
