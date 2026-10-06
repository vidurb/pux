import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'crypto_service.dart';

const _copyActionId = 'copy_code';

/// What a decrypted payload asks us to show. The server sends
/// `{"type": "otp", "otp", "sender"}` or
/// `{"type": "forward_confirm", "code", "url", "sender"}`; payloads without a
/// `type` predate the field and are OTPs.
@immutable
class RelayNotification {
  const RelayNotification({required this.title, required this.body, this.code});

  factory RelayNotification.fromPayload(Map<String, dynamic> payload) {
    final sender = payload['sender'] as String? ?? 'Unknown sender';

    switch (payload['type'] as String? ?? 'otp') {
      case 'forward_confirm':
        final code = payload['code'] as String?;
        final url = payload['url'] as String?;
        return RelayNotification(
          title: 'Email forwarding confirmation',
          body: [if (code != null) 'Code: $code', if (url != null) url, 'From $sender'].join('\n'),
          code: code,
        );
      case 'otp':
      default:
        final otp = payload['otp'] as String? ?? '??????';
        return RelayNotification(title: 'OTP from $sender', body: otp, code: otp);
    }
  }

  final String title;
  final String body;

  /// Offered through the "Copy code" action, when present.
  final String? code;
}

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  int _sequence = 0;

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    const linux = LinuxInitializationSettings(defaultActionName: 'Open notification');
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

    await _plugin.initialize(settings, onDidReceiveNotificationResponse: _onResponse);

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
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      final macPlugin = _plugin
          .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      await macPlugin?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  /// Decrypts and shows an encrypted envelope. Returns false when the
  /// envelope could not be decrypted, so callers do not acknowledge it.
  Future<bool> handleEncryptedMessage(Map<String, dynamic> data) async {
    final ciphertext = data['ciphertext'] as String?;
    if (ciphertext == null) {
      debugPrint('Ignoring envelope without ciphertext');
      return false;
    }

    final Map<String, dynamic> payload;
    try {
      payload = await CryptoService.instance.decryptPayload(ciphertext);
    } catch (error, stackTrace) {
      debugPrint('Failed to decrypt envelope: $error\n$stackTrace');
      return false;
    }

    await show(RelayNotification.fromPayload(payload));
    return true;
  }

  Future<void> show(RelayNotification notification) async {
    final androidDetails = AndroidNotificationDetails(
      'pux_otp',
      'OTP codes',
      channelDescription: 'Decrypted OTP notifications from pux',
      importance: Importance.max,
      priority: Priority.high,
      actions: [
        if (notification.code != null)
          const AndroidNotificationAction(_copyActionId, 'Copy code', showsUserInterface: true),
      ],
    );
    const darwinDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    const windowsDetails = WindowsNotificationDetails();

    await _plugin.show(
      _nextId(),
      notification.title,
      notification.body,
      NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
        macOS: darwinDetails,
        linux: linuxDetails,
        windows: windowsDetails,
      ),
      payload: notification.code,
    );
  }

  /// Unique per notification, so codes arriving in the same second do not
  /// replace each other.
  int _nextId() => (DateTime.now().millisecondsSinceEpoch + _sequence++) & 0x7fffffff;

  Future<void> _onResponse(NotificationResponse response) async {
    final code = response.payload;
    if (response.actionId == _copyActionId && code != null && code.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: code));
    }
  }
}
