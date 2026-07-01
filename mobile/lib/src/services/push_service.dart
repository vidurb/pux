import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'delivery_service.dart';
import 'notification_service.dart';
import 'record_store.dart';

class PushService implements DeliveryService {
  PushService._();

  static final PushService instance = PushService._();

  @override
  Future<void> init() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen((message) async {
      try {
        await NotificationService.instance.handleEncryptedMessage(message.data);
      } catch (error, stackTrace) {
        debugPrint('Foreground push handling failed: $error\n$stackTrace');
      }
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) async {
      try {
        await NotificationService.instance.handleEncryptedMessage(message.data);
      } catch (error, stackTrace) {
        debugPrint('Opened push handling failed: $error\n$stackTrace');
      }
    });

    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    final token = await messaging.getToken();
    if (token == null) return;

    await ApiClient.instance.registerDevice(
      recordId: recordId,
      pushToken: token,
      platform: 'fcm',
    );

    messaging.onTokenRefresh.listen((newToken) async {
      final id = await RecordStore.instance.recordId();
      if (id == null) return;
      try {
        await ApiClient.instance.registerDevice(
          recordId: id,
          pushToken: newToken,
          platform: 'fcm',
        );
      } catch (error, stackTrace) {
        debugPrint('Token refresh registration failed: $error\n$stackTrace');
      }
    });
  }
}
