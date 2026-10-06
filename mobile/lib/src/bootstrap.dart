import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

import 'firebase_options.dart';
import 'firebase_status.dart';
import 'platform.dart';
import 'services/crypto_service.dart';
import 'services/notification_service.dart';
import 'services/record_store.dart';

const _defaultServerUrl = String.fromEnvironment(
  'PUX_SERVER_URL',
  defaultValue: 'https://pux.vidur.xyz',
);

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _initLocalServices();
  await NotificationService.instance.handleEncryptedMessage(message.data);
}

Future<void> _initLocalServices() async {
  await RecordStore.instance.init(serverUrl: _defaultServerUrl);
  await CryptoService.instance.init();
  await NotificationService.instance.init();
}

/// Local-only setup that must finish before the first frame. Nothing here
/// touches the network; delivery starts afterwards via DeliveryController.
Future<void> bootstrap() async {
  await _initLocalServices();

  if (supportsFirebasePush && firebaseConfigured) {
    try {
      await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    } catch (error, stackTrace) {
      // PushService reports this as "not configured" on the home screen.
      debugPrint('Firebase initialisation failed: $error\n$stackTrace');
    }
  }
}
