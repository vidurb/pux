import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Whether a code can reach the user as a notification on this device.
enum NotificationAccess {
  /// Nothing we can detect is in the way. Always the answer where there is no
  /// permission to check, such as Linux.
  allowed,

  /// Nothing is shown for pux at all: the Android 13+ permission is denied or
  /// not yet granted, notifications are off for the app on any Android version,
  /// or iOS or macOS reports anything but authorized or provisional.
  off,

  /// Android only: the `pux_otp` channel is off, though the app's are on.
  channelOff,

  /// iOS and macOS: notifications arrive, but with no banner or alert. This is
  /// either provisional authorization or authorized with alerts turned off.
  quiet,
}

/// Reads the current notification state, and tracks it for the home screen.
///
/// Android goes through MainActivity, because the channel's state and its
/// settings page aren't available from a plugin. iOS and macOS use
/// flutter_local_notifications: firebase_messaging needs Firebase initialised,
/// which macOS never does and an unconfigured build can't.
class NotificationPermissions {
  NotificationPermissions._();

  static final NotificationPermissions instance = NotificationPermissions._();

  @visibleForTesting
  static const channel = MethodChannel('xyz.vidur.pux/notification_permissions');

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  int _latestCheck = 0;

  /// The last state read. A failed check leaves it as it was, so a warning
  /// doesn't disappear just because the OS didn't answer.
  final ValueNotifier<NotificationAccess> access = ValueNotifier(NotificationAccess.allowed);

  /// Reads the state again. Never throws.
  Future<void> refresh() async {
    final check = ++_latestCheck;
    final current = await _read();
    if (current != null && check == _latestCheck) access.value = current;
  }

  /// Runs a permission request, then reads what the OS actually decided. The
  /// request's own outcome says nothing about channels or later changes, and a
  /// failed request mustn't stop this device from registering for delivery.
  Future<void> request(Future<Object?> Function() ask) async {
    try {
      await ask();
    } catch (error) {
      debugPrint('Notification permission request failed: $error');
    }
    await refresh();
  }

  /// Opens the settings page that fixes the current state. Returns whether it
  /// opened.
  Future<bool> openSettings() async {
    if (kIsWeb) return false;

    try {
      final opened = switch (defaultTargetPlatform) {
        TargetPlatform.android => await channel.invokeMethod<bool>(
          access.value == NotificationAccess.channelOff
              ? 'openChannelSettings'
              : 'openNotificationSettings',
        ),
        TargetPlatform.iOS =>
          await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.openAppNotificationSettings(),
        TargetPlatform.macOS =>
          await _plugin
              .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
              ?.openAppNotificationSettings(),
        _ => false,
      };
      return opened ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException catch (error) {
      debugPrint('Could not open notification settings: $error');
      return false;
    }
  }

  /// The current state, or null if it couldn't be determined.
  Future<NotificationAccess?> _read() async {
    if (kIsWeb) return NotificationAccess.allowed;

    try {
      return switch (defaultTargetPlatform) {
        TargetPlatform.android => await _readAndroid(),
        TargetPlatform.iOS => _fromAppleOptions(
          await _plugin
              .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
              ?.checkPermissions(),
        ),
        TargetPlatform.macOS => _fromAppleOptions(
          await _plugin
              .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>()
              ?.checkPermissions(),
        ),
        _ => NotificationAccess.allowed,
      };
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      debugPrint('Could not read notification settings: $error');
      return null;
    }
  }

  Future<NotificationAccess?> _readAndroid() async {
    final status = await channel.invokeMapMethod<String, Object?>('getStatus');
    final appEnabled = status?['appEnabled'] as bool?;
    if (appEnabled == null) return null;
    if (!appEnabled) return NotificationAccess.off;
    // Null before Android 8, and until the first code creates the channel.
    return status?['channelEnabled'] == false
        ? NotificationAccess.channelOff
        : NotificationAccess.allowed;
  }

  /// `isEnabled` means exactly "authorized", so it's false for provisional,
  /// which is why that's checked first. It's also false for "not determined",
  /// but both Apple platforms have asked by the time the home screen appears,
  /// because [NotificationService.init] waits for the answer during startup.
  NotificationAccess? _fromAppleOptions(NotificationsEnabledOptions? options) {
    if (options == null) return null;
    if (options.isProvisionalEnabled) return NotificationAccess.quiet;
    if (!options.isEnabled) return NotificationAccess.off;
    return options.isAlertEnabled ? NotificationAccess.allowed : NotificationAccess.quiet;
  }
}
