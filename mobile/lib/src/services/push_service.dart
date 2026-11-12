import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import '../firebase_status.dart';
import '../push_display.dart';
import 'delivery_controller.dart';
import 'delivery_service.dart';
import 'fcm_registration.dart';
import 'notification_service.dart';

class PushService implements DeliveryService {
  PushService._();

  static final PushService instance = PushService._();

  StreamSubscription<RemoteMessage>? _messages;
  final FcmRegistration _registration = FcmRegistration(
    onRefreshError: DeliveryController.instance.reportError,
  );

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

    // Registers this phone's Firebase Installation ID, and any later one.
    await _registration.start();
  }

  @override
  Future<void> stop() async {
    await _messages?.cancel();
    await _registration.stop();
    _messages = null;
  }
}
