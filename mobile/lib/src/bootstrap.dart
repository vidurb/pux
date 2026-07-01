import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'firebase_options.dart';
import 'platform.dart';
import 'services/crypto_service.dart';
import 'services/delivery_runtime.dart';
import 'services/notification_service.dart';
import 'services/record_store.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await _initBackgroundServices();
  await NotificationService.instance.handleEncryptedMessage(message.data);
}

Future<void> _initBackgroundServices() async {
  const serverUrl = String.fromEnvironment(
    'PUX_SERVER_URL',
    defaultValue: 'https://pux.vidur.xyz',
  );

  await RecordStore.instance.init(serverUrl: serverUrl);
  await CryptoService.instance.init();
  await NotificationService.instance.init();
}

Future<void> bootstrap() async {
  const serverUrl = String.fromEnvironment(
    'PUX_SERVER_URL',
    defaultValue: 'https://pux.vidur.xyz',
  );

  await RecordStore.instance.init(serverUrl: serverUrl);
  await CryptoService.instance.init();
  await NotificationService.instance.init();

  if (supportsFirebasePush) {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  if (await RecordStore.instance.isEnrolled()) {
    await deliveryServiceForPlatform().init();
  }
}
