import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'services/crypto_service.dart';
import 'services/notification_service.dart';
import 'services/push_service.dart';
import 'services/record_store.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  await NotificationService.instance.handleEncryptedMessage(message.data);
}

Future<void> bootstrap() async {
  const serverUrl = String.fromEnvironment(
    'PUX_SERVER_URL',
    defaultValue: 'https://pux.vidur.xyz',
  );

  await RecordStore.instance.init(serverUrl: serverUrl);
  await CryptoService.instance.init();
  await NotificationService.instance.init();

  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await Firebase.initializeApp();
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    await PushService.instance.init();
  }
}
