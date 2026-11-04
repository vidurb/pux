import 'package:flutter/foundation.dart';

/// Whether the app shows FCM messages itself. On iOS the server sends an alert
/// push that the notification service extension decrypts and iOS displays
/// (in the foreground too), so showing it again would duplicate it.
bool get showsPushNotificationsLocally => kIsWeb || defaultTargetPlatform != TargetPlatform.iOS;
