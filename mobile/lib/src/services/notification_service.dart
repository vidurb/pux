import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'crypto_service.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings();
    const linux = LinuxInitializationSettings(defaultActionName: 'Open notification');
    const windows = WindowsInitializationSettings(
      appName: 'pux',
      appUserModelId: 'xyz.vidur.pux',
      guid: 'a1b2c3d4-e5f6-7890-abcd-ef1234567890',
    );

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    await _plugin.initialize(settings);

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await iosPlugin?.requestPermissions(alert: true, badge: true, sound: true);
    }

    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      final macPlugin =
          _plugin.resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      await macPlugin?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> handleEncryptedMessage(Map<String, dynamic> data) async {
    final ciphertext = data['ciphertext'] as String?;
    if (ciphertext == null) return;

    try {
      final payload = await CryptoService.instance.decryptPayload(ciphertext);
      final otp = payload['otp'] as String? ?? '??????';
      final sender = payload['sender'] as String? ?? 'Unknown sender';

      await showOtpNotification(sender: sender, otp: otp);
    } catch (error, stackTrace) {
      debugPrint('Failed to handle encrypted push: $error\n$stackTrace');
    }
  }

  Future<void> showOtpNotification({
    required String sender,
    required String otp,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      'pux_otp',
      'OTP codes',
      channelDescription: 'Decrypted OTP notifications from pux',
      importance: Importance.max,
      priority: Priority.high,
    );
    const darwinDetails = DarwinNotificationDetails();
    const linuxDetails = LinuxNotificationDetails();
    const windowsDetails = WindowsNotificationDetails();

    const details = NotificationDetails(
      android: androidDetails,
      iOS: darwinDetails,
      macOS: darwinDetails,
      linux: linuxDetails,
      windows: windowsDetails,
    );

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'OTP from $sender',
      otp,
      details,
    );
  }
}
