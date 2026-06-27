import 'package:firebase_messaging/firebase_messaging.dart';

import 'api_client.dart';
import 'notification_service.dart';
import 'record_store.dart';

class PushService {
  PushService._();

  static final PushService instance = PushService._();

  Future<void> init() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission();
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen((message) async {
      await NotificationService.instance.handleEncryptedMessage(message.data);
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) async {
      await NotificationService.instance.handleEncryptedMessage(message.data);
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
      await ApiClient.instance.registerDevice(
        recordId: id,
        pushToken: newToken,
        platform: 'fcm',
      );
    });
  }
}
