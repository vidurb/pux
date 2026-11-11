import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'crypto_service.dart';
import 'sensitive_clipboard.dart';

const _copyActionId = 'copy_code';

/// What a decrypted payload asks us to show. The server sends
/// `{"type": "otp", "otp", "sender", "verified"}` or
/// `{"type": "forward_confirm", "code", "url", "sender", "forwarding_from"}`
/// (code, url and forwarding_from may be null); payloads without a
/// `type` predate the field and are OTPs. `verified: false` means the
/// sender could not be authenticated (no aligned DKIM signature); payloads
/// without the key come from older servers and carry no marker.
@immutable
class RelayNotification {
  const RelayNotification({required this.title, required this.body, this.code});

  factory RelayNotification.fromPayload(Map<String, dynamic> payload) {
    final sender = payload['sender'] as String? ?? 'Unknown sender';

    switch (payload['type'] as String? ?? 'otp') {
      case 'forward_confirm':
        final code = payload['code'] as String?;
        final url = payload['url'] as String?;
        final from = payload['forwarding_from'] as String?;
        return RelayNotification(
          title: 'Email forwarding confirmation',
          body: [
            if (from != null) 'Forwarding from $from',
            if (code != null) 'Code: $code',
            ?url,
            if (from == null) 'From $sender',
          ].join('\n'),
          code: code,
        );
      case 'otp':
      default:
        final otp = payload['otp'] as String? ?? '??????';
        final marker = payload['verified'] == false ? ' (unverified)' : '';
        return RelayNotification(
          title: 'OTP from $sender$marker',
          body: otp,
          code: otp,
        );
    }
  }

  final String title;
  final String body;

  /// Offered through the "Copy code" action, when present.
  final String? code;
}

/// Codes for the "Copy code" action, kept in memory by notification ID so the
/// code never becomes the plugin's payload. Nothing here is written to disk, so
/// after a restart the action finds nothing and does nothing.
@visibleForTesting
class NotificationCodes {
  NotificationCodes({this.lifetime = codeLifetime});

  /// As long as a desktop holds a code (`DesktopDeliveryService._holdFor`): the
  /// server's 10 minute limit plus up to 5 until its pruner runs. A code is no
  /// use after that, so the action stops offering it.
  static const codeLifetime = Duration(minutes: 15);

  final Duration lifetime;
  final Map<int, String> _codes = {};
  final Map<int, Timer> _expiry = {};

  int get length => _codes.length;

  void put(int id, String code) {
    _expiry.remove(id)?.cancel();
    _codes[id] = code;
    _expiry[id] = Timer(lifetime, () => remove(id));
  }

  /// The code for [id], if it hasn't expired. Removes it: the notification has
  /// been answered, which closes it.
  String? take(int id) {
    final code = _codes[id];
    remove(id);
    return code;
  }

  void remove(int id) {
    _expiry.remove(id)?.cancel();
    _codes.remove(id);
  }
}

class NotificationService {
  NotificationService._([FlutterLocalNotificationsPlugin? plugin])
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// For platforms whose plugin can't be faked through a method channel.
  @visibleForTesting
  factory NotificationService.forTesting(
    FlutterLocalNotificationsPlugin plugin,
  ) => NotificationService._(plugin);

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin;
  int _sequence = 0;

  @visibleForTesting
  final NotificationCodes codes = NotificationCodes();

  /// Where the "Copy code" action finds its code.
  ///
  /// - Android: in the payload. The system keeps it in the action's intent, not
  ///   in a file, and the action can arrive after the process that showed the
  ///   notification (often the FCM background isolate) has gone.
  /// - Linux: in [codes]. The plugin writes every payload to
  ///   `notification_plugin_cache.json` under `$XDG_RUNTIME_DIR`, a file this
  ///   app doesn't control. Desktop codes only arrive while the app runs, and
  ///   the action is answered by the same process, so memory is enough.
  /// - Elsewhere there is no action, so the code isn't passed on at all. macOS
  ///   would keep it in the notification's userInfo, and Windows in the toast's
  ///   launch arguments.
  static bool get _codeInPayload =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get _codeInMemory =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  Future<void> init() async {
    const android = AndroidInitializationSettings('@drawable/ic_stat_pux');
    const darwin = DarwinInitializationSettings();
    const linux = LinuxInitializationSettings(
      defaultActionName: 'Open notification',
    );
    const windows = WindowsInitializationSettings(
      appName: 'pux',
      appUserModelId: 'xyz.vidur.pux',
      guid: 'a4d8b6ca-6b60-4901-9d08-5d79686765f4',
    );

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: _onResponse,
    );

    // Not available in the FCM background isolate on every platform.
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final response = launch?.notificationResponse;
      if (launch?.didNotificationLaunchApp == true && response != null) {
        await _onResponse(response);
      }
    } catch (error) {
      debugPrint('Notification launch details unavailable: $error');
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final iosPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      await iosPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      final macPlugin = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      await macPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    }
  }

  /// Decrypts and shows an encrypted envelope. Returns false when the
  /// envelope could not be decrypted, so callers do not acknowledge it.
  Future<bool> handleEncryptedMessage(Map<String, dynamic> data) async {
    final notification = await decrypt(data);
    if (notification == null) return false;

    await show(notification);
    return true;
  }

  /// Decrypts an envelope, or returns null if that isn't possible.
  Future<RelayNotification?> decrypt(Map<String, dynamic> data) async {
    final ciphertext = data['ciphertext'] as String?;
    if (ciphertext == null) {
      debugPrint('Ignoring envelope without ciphertext');
      return null;
    }

    try {
      final payload = await CryptoService.instance.decryptPayload(ciphertext);
      return RelayNotification.fromPayload(payload);
    } catch (error, stackTrace) {
      debugPrint('Failed to decrypt envelope: $error\n$stackTrace');
      return null;
    }
  }

  Future<void> show(RelayNotification notification) async {
    final androidDetails = AndroidNotificationDetails(
      'pux_otp',
      'OTP codes',
      channelDescription: 'Decrypted OTP notifications from pux',
      importance: Importance.max,
      priority: Priority.high,
      // On a secure lock screen Android shows only "pux" with the contents
      // hidden. flutter_local_notifications cannot set a custom public version.
      visibility: NotificationVisibility.private,
      actions: [
        if (notification.code != null)
          const AndroidNotificationAction(
            _copyActionId,
            'Copy code',
            showsUserInterface: true,
          ),
      ],
    );
    const darwinDetails = DarwinNotificationDetails();
    final linuxDetails = LinuxNotificationDetails(
      actions: [
        if (notification.code != null)
          const LinuxNotificationAction(key: _copyActionId, label: 'Copy code'),
      ],
    );
    const windowsDetails = WindowsNotificationDetails();

    final id = _nextId();
    final code = notification.code;
    if (code != null && _codeInMemory) codes.put(id, code);

    try {
      await _plugin.show(
        id: id,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
          linux: linuxDetails,
          windows: windowsDetails,
        ),
        payload: _codeInPayload ? code : null,
      );
    } catch (_) {
      codes.remove(id);
      rethrow;
    }
  }

  /// Unique per notification, so codes arriving in the same second do not
  /// replace each other.
  int _nextId() =>
      (DateTime.now().millisecondsSinceEpoch + _sequence++) & 0x7fffffff;

  Future<void> _onResponse(NotificationResponse response) async {
    final id = response.id;
    // Outside Android the payload is never a code, so it isn't read. A Linux
    // notification left from before a restart finds nothing and copies nothing.
    final code = _codeInPayload
        ? response.payload
        : (id == null ? null : codes.take(id));
    if (response.actionId == _copyActionId && code != null && code.isNotEmpty) {
      await SensitiveClipboard.instance.copy(code);
    }
  }
}
