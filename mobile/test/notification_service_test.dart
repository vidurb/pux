import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/notification_service.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  String? clipboard;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    calls = [];
    clipboard = null;
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return call.method == 'initialize' ? true : null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(_channel, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Map<dynamic, dynamic> shownArguments() =>
      calls.singleWhere((call) => call.method == 'show').arguments as Map<dynamic, dynamic>;

  test('Android notifications are private and offer Copy code', () async {
    await NotificationService.instance.show(
      const RelayNotification(title: 'OTP from Bank', body: '123456', code: '123456'),
    );

    final arguments = shownArguments();
    expect(arguments['title'], 'OTP from Bank');
    expect(arguments['body'], '123456');
    expect(arguments['payload'], '123456');

    final android = arguments['platformSpecifics'] as Map<dynamic, dynamic>;
    expect(android['channelId'], 'pux_otp');
    expect(android['visibility'], NotificationVisibility.private.index);

    final action = (android['actions'] as List<dynamic>).single as Map<dynamic, dynamic>;
    expect(action['id'], 'copy_code');
    expect(action['title'], 'Copy code');
    expect(action['showsUserInterface'], isTrue);
  });

  test('Android notifications without a code have no action', () async {
    await NotificationService.instance.show(
      const RelayNotification(title: 'Email forwarding confirmation', body: 'From Google'),
    );

    final android = shownArguments()['platformSpecifics'] as Map<dynamic, dynamic>;
    expect(android['actions'], anyOf(isNull, isEmpty));
  });

  test('the Copy code action copies the code from the payload', () async {
    await NotificationService.instance.init();

    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
        const MethodCall('didReceiveNotificationResponse', {
          'notificationId': 1,
          'actionId': 'copy_code',
          'payload': '123456',
          'notificationResponseType': 1,
        }),
      ),
      (_) {},
    );
    await pumpEventQueue();

    expect(clipboard, '123456');
  });

  test('tapping the notification itself does not copy', () async {
    await NotificationService.instance.init();

    await messenger.handlePlatformMessage(
      _channel.name,
      _channel.codec.encodeMethodCall(
        const MethodCall('didReceiveNotificationResponse', {
          'notificationId': 1,
          'payload': '123456',
          'notificationResponseType': 0,
        }),
      ),
      (_) {},
    );
    await pumpEventQueue();

    expect(clipboard, isNull);
  });
}
