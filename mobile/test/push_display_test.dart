import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/push_display.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('iOS leaves FCM notifications to the notification service extension', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    expect(showsPushNotificationsLocally, isFalse);
  });

  test('Android shows FCM notifications itself', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    expect(showsPushNotificationsLocally, isTrue);
  });
}
