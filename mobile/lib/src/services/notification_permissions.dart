import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'background_restrictions.dart';

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
/// which macOS never does and an unconfigured build can't. iOS also asks
/// AppDelegate, on the same channel name as Android, about the scheduled
/// summary, which the plugin doesn't report.
class NotificationPermissions {
  NotificationPermissions._();

  static final NotificationPermissions instance = NotificationPermissions._();

  @visibleForTesting
  static const channel = MethodChannel(
    'xyz.vidur.pux/notification_permissions',
  );

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  int _latestCheck = 0;

  /// The last state read. A failed check leaves it as it was, so a warning
  /// doesn't disappear just because the OS didn't answer.
  final ValueNotifier<NotificationAccess> access = ValueNotifier(
    NotificationAccess.allowed,
  );

  /// Settings that let codes arrive unnoticed though [access] may be allowed:
  /// [DeliveryRestriction.quietChannel] on Android and
  /// [DeliveryRestriction.scheduledSummary] on iOS. A failed check leaves it as
  /// it was, like [access].
  final ValueNotifier<DeliveryRestrictionStatus> quietDelivery = ValueNotifier(
    const DeliveryRestrictionStatus(),
  );

  /// Reads the state again. Never throws.
  Future<void> refresh() => check();

  /// Reads the state again and returns it, or null if it couldn't be determined
  /// within [timeout]. Never throws.
  Future<NotificationAccess?> check({Duration? timeout}) async {
    final check = ++_latestCheck;
    final (current, quiet) = await _read(timeout);
    if (check == _latestCheck) {
      if (current != null) access.value = current;
      if (quiet != null) quietDelivery.value = quiet;
    }
    return current;
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
  Future<bool> openSettings() => _openSettings(
    android: access.value == NotificationAccess.channelOff
        ? 'openChannelSettings'
        : 'openNotificationSettings',
  );

  /// Opens the settings page that fixes one of the [quietDelivery]
  /// restrictions: the channel's own page on Android, where its importance is
  /// set, and the app's notification page on iOS. Returns whether it opened.
  Future<bool> openQuietDeliverySettings() =>
      _openSettings(android: 'openChannelSettings');

  /// On iOS and macOS the plugin opens the app's notification page where it
  /// can, and the app's settings page otherwise.
  Future<bool> _openSettings({required String android}) async {
    if (kIsWeb) return false;

    try {
      final opened = switch (defaultTargetPlatform) {
        TargetPlatform.android => await channel.invokeMethod<bool>(android),
        TargetPlatform.iOS =>
          await _plugin
              .resolvePlatformSpecificImplementation<
                IOSFlutterLocalNotificationsPlugin
              >()
              ?.openAppNotificationSettings(),
        TargetPlatform.macOS =>
          await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
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

  /// The current state, with null for whatever couldn't be determined.
  Future<(NotificationAccess?, DeliveryRestrictionStatus?)> _read(
    Duration? timeout,
  ) async {
    try {
      final read = _readPlatform();
      return await (timeout == null ? read : read.timeout(timeout));
    } on MissingPluginException {
      return (null, null);
    } catch (error) {
      debugPrint('Could not read notification settings: $error');
      return (null, null);
    }
  }

  Future<(NotificationAccess?, DeliveryRestrictionStatus?)>
  _readPlatform() async {
    if (kIsWeb) return (NotificationAccess.allowed, null);

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => await _readAndroid(),
      TargetPlatform.iOS => await _readIOS(),
      TargetPlatform.macOS => (
        _fromAppleOptions(
          await _plugin
              .resolvePlatformSpecificImplementation<
                MacOSFlutterLocalNotificationsPlugin
              >()
              ?.checkPermissions(),
        ),
        null,
      ),
      _ => (NotificationAccess.allowed, null),
    };
  }

  Future<(NotificationAccess?, DeliveryRestrictionStatus?)>
  _readAndroid() async {
    final status = await channel.invokeMapMethod<String, Object?>('getStatus');
    final appEnabled = status?['appEnabled'] as bool?;
    if (appEnabled == null) return (null, null);
    // Null before Android 8, until the first code creates the channel, and
    // while the channel is off, which the access prompt covers.
    final quiet = _status(
      DeliveryRestriction.quietChannel,
      status?['channelQuiet'] as bool?,
    );
    if (!appEnabled) return (NotificationAccess.off, quiet);
    // Null before Android 8, and until the first code creates the channel.
    final access = status?['channelEnabled'] == false
        ? NotificationAccess.channelOff
        : NotificationAccess.allowed;
    return (access, quiet);
  }

  Future<(NotificationAccess?, DeliveryRestrictionStatus?)> _readIOS() async {
    final summary = _readScheduledSummary();
    final options = await _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >()
        ?.checkPermissions();
    return (_fromAppleOptions(options), await summary);
  }

  /// Null if AppDelegate couldn't say, which mustn't lose what the plugin read.
  Future<DeliveryRestrictionStatus?> _readScheduledSummary() async {
    try {
      final status = await channel.invokeMapMethod<String, Object?>(
        'getStatus',
      );
      return _status(
        DeliveryRestriction.scheduledSummary,
        status?['scheduledSummary'] as bool?,
      );
    } on MissingPluginException {
      return null;
    } catch (error) {
      debugPrint('Could not read the scheduled summary setting: $error');
      return null;
    }
  }

  static DeliveryRestrictionStatus _status(
    DeliveryRestriction restriction,
    bool? active,
  ) => DeliveryRestrictionStatus(
    active: {if (active == true) restriction},
    clear: {if (active == false) restriction},
  );

  /// `isEnabled` means exactly "authorized", so it's false for provisional,
  /// which is why that's checked first. It's also false for "not determined",
  /// but both Apple platforms have asked by the time the home screen appears,
  /// because [NotificationService.init] waits for the answer during startup.
  NotificationAccess? _fromAppleOptions(NotificationsEnabledOptions? options) {
    if (options == null) return null;
    if (options.isProvisionalEnabled) return NotificationAccess.quiet;
    if (!options.isEnabled) return NotificationAccess.off;
    return options.isAlertEnabled
        ? NotificationAccess.allowed
        : NotificationAccess.quiet;
  }
}
