import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_status.dart';
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
    await messaging.requestPermission();
    await messaging.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    // Data-only messages: shown by us, in the foreground here and in the
    // background by firebaseMessagingBackgroundHandler.
    _messages ??= FirebaseMessaging.onMessage.listen((message) async {
      try {
        await NotificationService.instance.handleEncryptedMessage(message.data);
      } catch (error, stackTrace) {
        debugPrint('Foreground push handling failed: $error\n$stackTrace');
      }
    });

    _tokenRefresh ??= messaging.onTokenRefresh.listen((newToken) async {
      try {
        await _register(newToken);
      } catch (error) {
        DeliveryController.instance.reportError(error);
      }
    });

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

    await ApiClient.instance.registerDevice(recordId: recordId, pushToken: token, platform: 'fcm');
  }
}
