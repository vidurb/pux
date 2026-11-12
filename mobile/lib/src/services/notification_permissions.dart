import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'record_store.dart';

/// Whether a code can reach the user as a notification on this device.
enum NotificationAccess {
  /// Nothing we can detect is in the way. Always the answer where there is no
  /// permission to check, such as Linux.
  allowed,

  /// Nothing is shown for pux at all: the Android 13+ permission is denied,
  /// notifications are off for the app on any Android version, or iOS or macOS
  /// reports denied. Only the settings app can change this.
  off,

  /// Nothing is shown for pux yet, because the user has never been asked: iOS
  /// and macOS report "not determined", or the Android 13+ permission isn't
  /// granted and pux has never asked for it. [NotificationPermissions.ask] shows
  /// the system prompt, after NotificationExplainer has said why.
  notAsked,

  /// Android only: the `pux_otp` channel is off, though the app's are on.
  channelOff,

  /// iOS and macOS: notifications arrive, but with no banner or alert. This is
  /// either provisional authorization or authorized with alerts turned off.
  quiet,
}

extension NotificationAccessHidden on NotificationAccess {
  /// Whether the OS shows nothing for pux, so a code shown now would be lost.
  bool get hidesCodes =>
      this == NotificationAccess.off || this == NotificationAccess.notAsked;
}

/// Reads the current notification state, tracks it for the home screen, and
/// asks for it.
///
/// Nothing asks at startup: the system prompt only appears from [ask], which
/// NotificationExplainer calls once it has said why pux needs notifications.
///
/// Android goes through MainActivity, because the channel's state and its
/// settings page aren't available from a plugin. iOS and macOS use
/// flutter_local_notifications, plus the app's own channel for "not
/// determined", which the plugin reports as a denial: firebase_messaging needs
/// Firebase initialised, which macOS never does and an unconfigured build can't.
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

  /// Reads the state again. Never throws.
  Future<void> refresh() => check();

  /// Reads the state again and returns it, or null if it couldn't be determined
  /// within [timeout]. Never throws.
  Future<NotificationAccess?> check({Duration? timeout}) async {
    final check = ++_latestCheck;
    final current = await _read(timeout);
    if (current != null && check == _latestCheck) access.value = current;
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

  /// Shows the system prompt where the OS still has one to show
  /// ([NotificationAccess.notAsked]), then reads what the user decided. Never
  /// throws.
  ///
  /// On Android, also records that pux has asked: afterwards a permission that
  /// isn't granted is a denial, which only the settings app can undo.
  Future<void> ask() => request(() async {
    final answer = await _askPlatform();
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await RecordStore.instance.saveNotificationPermissionAsked();
      } catch (error) {
        debugPrint(
          'Could not record the notification permission request: $error',
        );
      }
    }
    return answer;
  });

  Future<Object?> _askPlatform() async {
    if (kIsWeb) return null;

    return switch (defaultTargetPlatform) {
      TargetPlatform.android =>
        await _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission(),
      TargetPlatform.iOS =>
        await _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true),
      TargetPlatform.macOS =>
        await _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true),
      _ => null,
    };
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

  /// The current state, or null if it couldn't be determined.
  Future<NotificationAccess?> _read(Duration? timeout) async {
    try {
      final read = _readPlatform();
      return await (timeout == null ? read : read.timeout(timeout));
    } on MissingPluginException {
      return null;
    } catch (error) {
      debugPrint('Could not read notification settings: $error');
      return null;
    }
  }

  Future<NotificationAccess?> _readPlatform() async {
    if (kIsWeb) return NotificationAccess.allowed;

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => await _readAndroid(),
      TargetPlatform.iOS => await _readApple(
        () async => _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions(),
      ),
      TargetPlatform.macOS => await _readApple(
        () async => _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >()
            ?.checkPermissions(),
      ),
      _ => NotificationAccess.allowed,
    };
  }

  Future<NotificationAccess?> _readApple(
    Future<NotificationsEnabledOptions?> Function() checkPermissions,
  ) async {
    if (await _appleNotDetermined()) return NotificationAccess.notAsked;
    return _fromAppleOptions(await checkPermissions());
  }

  /// Whether iOS or macOS reports "not determined", from AppDelegate (iOS) or
  /// MainFlutterWindow (macOS). False where that channel isn't registered, such
  /// as the FCM background isolate, which never shows the home screen anyway.
  Future<bool> _appleNotDetermined() async {
    try {
      return await channel.invokeMethod<String>('getAuthorizationStatus') ==
          'notDetermined';
    } on MissingPluginException {
      return false;
    }
  }

  Future<NotificationAccess?> _readAndroid() async {
    final status = await channel.invokeMapMethod<String, Object?>('getStatus');
    final appEnabled = status?['appEnabled'] as bool?;
    if (appEnabled == null) return null;
    if (!appEnabled) {
      // "notGranted" is also what a permission denied for good looks like, so
      // only pux's own record tells them apart.
      final neverAsked =
          status?['permission'] == 'notGranted' && !await _askedBefore();
      return neverAsked ? NotificationAccess.notAsked : NotificationAccess.off;
    }
    // Null before Android 8, and until the first code creates the channel.
    return status?['channelEnabled'] == false
        ? NotificationAccess.channelOff
        : NotificationAccess.allowed;
  }

  /// Whether pux has asked for the Android permission before, counting a
  /// failed read as yes: that only costs the explainer, while a wrong no would
  /// offer a prompt Android won't show.
  Future<bool> _askedBefore() async {
    try {
      return await RecordStore.instance.notificationPermissionAsked();
    } catch (error) {
      debugPrint('Could not read the notification permission record: $error');
      return true;
    }
  }

  /// `isEnabled` means exactly "authorized", so it's false for provisional,
  /// which is why that's checked first. It's also false for "not determined",
  /// which nothing asks about at startup any more, so [_readApple] checks for
  /// that first and only a denial reaches here. Where that check can't run, a
  /// "not determined" also reads as [NotificationAccess.off].
  NotificationAccess? _fromAppleOptions(NotificationsEnabledOptions? options) {
    if (options == null) return null;
    if (options.isProvisionalEnabled) return NotificationAccess.quiet;
    if (!options.isEnabled) return NotificationAccess.off;
    return options.isAlertEnabled
        ? NotificationAccess.allowed
        : NotificationAccess.quiet;
  }
}
