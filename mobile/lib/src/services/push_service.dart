import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_status.dart';
import '../push_display.dart';
import 'api_client.dart';
import 'delivery_controller.dart';
import 'delivery_service.dart';
import 'notification_service.dart';
import 'record_store.dart';

class PushService implements DeliveryService {
  PushService._();

  static final PushService instance = PushService._();

  StreamSubscription<RemoteMessage>? _messages;
  StreamSubscription<String>? _tokenRefresh;

  @override
  Future<void> init() async {
    if (!firebaseConfigured || Firebase.apps.isEmpty) {
      throw const FirebaseNotConfiguredException();
    }

    final messaging = FirebaseMessaging.instance;
    // Never asks for notification permission: NotificationExplainer does, after
    // saying why. Registration goes ahead whatever the answer, or with none
    // yet: the server keeps this device alive, and codes reach it as soon as
    // the user allows notifications. iOS gets its APNs token without
    // permission too (AppDelegate registers for remote notifications).
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Android gets data-only messages: shown by us, in the foreground here and
    // in the background by firebaseMessagingBackgroundHandler. iOS displays its
    // alert pushes itself, decrypted by the notification service extension.
    _messages ??= FirebaseMessaging.onMessage.listen((message) async {
      if (!showsPushNotificationsLocally) return;
      try {
        await NotificationService.instance.handleEncryptedMessage(message.data);
      } catch (error, stackTrace) {
        debugPrint('Foreground push handling failed: $error\n$stackTrace');
      }
    });

    // getToken and onTokenRefresh are deprecated in favour of register and
    // onRegistered, which yield a Firebase Installation ID instead of a token.
    // They keep working until the app opts in to FID mode. That needs a planned
    // client and server change: a new ID would add a second device row beside
    // the old token, so one phone could get every code twice.
    // ignore: deprecated_member_use
    _tokenRefresh ??= messaging.onTokenRefresh.listen((newToken) async {
      try {
        await _register(newToken);
      } catch (error) {
        DeliveryController.instance.reportError(error);
      }
    });

    // ignore: deprecated_member_use
    final token = await messaging.getToken();
    if (token == null) {
      throw Exception('Firebase returned no push token');
    }
    await _register(token);
  }

  @override
  Future<void> stop() async {
    await _messages?.cancel();
    await _tokenRefresh?.cancel();
    _messages = null;
    _tokenRefresh = null;
  }

  Future<void> _register(String token) async {
    final recordId = await RecordStore.instance.recordId();
    if (recordId == null) return;

    final deviceId = await ApiClient.instance.registerDevice(
      recordId: recordId,
      pushToken: token,
      platform: 'fcm',
    );
    await RecordStore.instance.saveDeviceId(deviceId);
  }
}
