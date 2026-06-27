import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'crypto_service.dart';

class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  Future<void> init() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios);
    await _plugin.initialize(settings);
  }

  Future<void> handleEncryptedMessage(Map<String, dynamic> data) async {
    final ciphertext = data['ciphertext'] as String?;
    if (ciphertext == null) return;

    final payload = await CryptoService.instance.decryptPayload(ciphertext);
    final otp = payload['otp'] as String? ?? '??????';
    final sender = payload['sender'] as String? ?? 'Unknown sender';

    const androidDetails = AndroidNotificationDetails(
      'pux_otp',
      'OTP codes',
      channelDescription: 'Decrypted OTP notifications from pux',
      importance: Importance.max,
      priority: Priority.high,
    );

    const details = NotificationDetails(android: androidDetails);

    await _plugin.show(
      DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'OTP from $sender',
      otp,
      details,
    );
  }
}
