import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Whether pux opens when the user logs in. The system keeps this, so the
/// user can also change it outside pux.
enum LaunchAtLogin {
  enabled,
  disabled,

  /// Registered, but the user has to allow it in System Settings.
  requiresApproval,

  /// The OS can't do it (macOS before 13).
  unsupported;

  static LaunchAtLogin parse(Object? value) => switch (value) {
    'enabled' => enabled,
    'requiresApproval' => requiresApproval,
    'disabled' => disabled,
    _ => unsupported,
  };
}

@immutable
class DesktopSettings {
  const DesktopSettings({
    required this.closeQuits,
    required this.startHidden,
    required this.launchAtLogin,
  });

  factory DesktopSettings.fromMap(Map<Object?, Object?> map) => DesktopSettings(
    closeQuits: map['closeQuits'] == true,
    startHidden: map['startHidden'] == true,
    launchAtLogin: LaunchAtLogin.parse(map['launchAtLogin']),
  );

  /// Closing the window quits pux instead of leaving it in the menu bar.
  final bool closeQuits;

  /// pux starts with only its menu bar icon, without a window.
  final bool startHidden;

  final LaunchAtLogin launchAtLogin;
}

/// The macOS menu bar app around the Flutter window (DesktopShell.swift):
/// its settings, and showing the window from Dart. Settings are stored
/// natively because they apply before Flutter starts and after it stops.
class DesktopShell {
  DesktopShell._();

  static final DesktopShell instance = DesktopShell._();

  @visibleForTesting
  static const channel = MethodChannel('xyz.vidur.pux/desktop_shell');

  /// Only macOS has the menu bar app so far.
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  /// Calls [onOpenSettings] when the user picks Settings… in the menu bar.
  void listen({required VoidCallback onOpenSettings}) {
    if (!isSupported) return;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'openSettings') onOpenSettings();
    });
  }

  Future<DesktopSettings> load() => _settings('getSettings');

  Future<DesktopSettings> setCloseQuits(bool enabled) =>
      _settings('setCloseQuits', {'enabled': enabled});

  Future<DesktopSettings> setStartHidden(bool enabled) =>
      _settings('setStartHidden', {'enabled': enabled});

  /// Throws [PlatformException] when the system refuses.
  Future<DesktopSettings> setLaunchAtLogin(bool enabled) =>
      _settings('setLaunchAtLogin', {'enabled': enabled});

  /// Opens System Settings → General → Login Items.
  Future<void> openLoginItemsSettings() =>
      channel.invokeMethod<void>('openLoginItemsSettings');

  /// Brings the window back from the menu bar. Does nothing elsewhere.
  Future<void> showWindow() async {
    if (!isSupported) return;
    try {
      await channel.invokeMethod<void>('showWindow');
    } on MissingPluginException {
      // Not registered in this engine.
    } on PlatformException catch (error) {
      debugPrint('Could not show the window: $error');
    }
  }

  Future<DesktopSettings> _settings(String method, [Object? arguments]) async {
    final map = await channel.invokeMapMethod<Object?, Object?>(
      method,
      arguments,
    );
    if (map == null) throw StateError('$method returned no settings');
    return DesktopSettings.fromMap(map);
  }
}
