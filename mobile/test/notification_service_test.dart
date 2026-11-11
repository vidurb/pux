import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/notification_service.dart';

const _channel = MethodChannel('dexterous.com/flutter/local_notifications');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

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
      calls.singleWhere((call) => call.method == 'show').arguments
          as Map<dynamic, dynamic>;

  test('Android notifications are private and offer Copy code', () async {
    await NotificationService.instance.show(
      const RelayNotification(
        title: 'OTP from Bank',
        body: '123456',
        code: '123456',
      ),
    );

    final arguments = shownArguments();
    expect(arguments['title'], 'OTP from Bank');
    expect(arguments['body'], '123456');
    expect(arguments['payload'], '123456');

    final android = arguments['platformSpecifics'] as Map<dynamic, dynamic>;
    expect(android['channelId'], 'pux_otp');
    expect(android['visibility'], NotificationVisibility.private.index);

    final action =
        (android['actions'] as List<dynamic>).single as Map<dynamic, dynamic>;
    expect(action['id'], 'copy_code');
    expect(action['title'], 'Copy code');
    expect(action['showsUserInterface'], isTrue);
  });

  test('Android notifications without a code have no action', () async {
    await NotificationService.instance.show(
      const RelayNotification(
        title: 'Email forwarding confirmation',
        body: 'From Google',
      ),
    );

    final android =
        shownArguments()['platformSpecifics'] as Map<dynamic, dynamic>;
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

  test('macOS notifications carry no payload', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    MacOSFlutterLocalNotificationsPlugin.registerWith();

    await NotificationService.instance.show(
      const RelayNotification(
        title: 'OTP from Bank',
        body: '123456',
        code: '123456',
      ),
    );

    // The plugin sends null as ''.
    expect(shownArguments()['payload'], isEmpty);
    expect(NotificationService.instance.codes.length, 0);
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

  group('on Linux', () {
    late _FakePlugin plugin;
    late NotificationService service;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      plugin = _FakePlugin();
      service = NotificationService.forTesting(plugin);
    });

    Future<void> respond(int id, {String? actionId, String? payload}) async {
      // The plugin drops the callback's future, as the real one does.
      plugin.respond!(
        NotificationResponse(
          id: id,
          actionId: actionId,
          payload: payload,
          notificationResponseType: actionId == null
              ? NotificationResponseType.selectedNotification
              : NotificationResponseType.selectedNotificationAction,
        ),
      );
      await pumpEventQueue();
    }

    test('the code stays in memory, not in the payload', () async {
      await service.init();
      await service.show(
        const RelayNotification(
          title: 'OTP from Bank',
          body: '123456',
          code: '123456',
        ),
      );

      final shown = plugin.shown.single;
      expect(shown.payload, isNull);
      final action = shown.details!.linux!.actions.single;
      expect(action.key, 'copy_code');
      expect(action.label, 'Copy code');
      expect(service.codes.length, 1);
    });

    test(
      'Copy code copies the code kept for that notification, once',
      () async {
        await service.init();
        await service.show(
          const RelayNotification(
            title: 'OTP from Bank',
            body: '123456',
            code: '123456',
          ),
        );
        final id = plugin.shown.single.id;

        await respond(id, actionId: 'copy_code');
        expect(clipboard, '123456');
        expect(service.codes.length, 0);

        clipboard = null;
        await respond(id, actionId: 'copy_code');
        expect(clipboard, isNull);
      },
    );

    test('tapping the notification forgets its code without copying', () async {
      await service.init();
      await service.show(
        const RelayNotification(
          title: 'OTP from Bank',
          body: '123456',
          code: '123456',
        ),
      );

      await respond(plugin.shown.single.id);
      expect(clipboard, isNull);
      expect(service.codes.length, 0);
    });

    test(
      'after a restart Copy code copies nothing, whatever the payload',
      () async {
        // The plugin's cache outlives the process, so an older build's
        // notification can still answer with its plain code as the payload.
        plugin.launchResponse = const NotificationResponse(
          id: 42,
          actionId: 'copy_code',
          payload: '123456',
          notificationResponseType:
              NotificationResponseType.selectedNotificationAction,
        );

        await service.init();
        await respond(43, actionId: 'copy_code', payload: '654321');

        expect(clipboard, isNull);
      },
    );

    test(
      'notifications without a code have no action and keep nothing',
      () async {
        await service.init();
        await service.show(
          const RelayNotification(
            title: 'Email forwarding confirmation',
            body: 'From Google',
          ),
        );

        expect(plugin.shown.single.details!.linux!.actions, isEmpty);
        expect(service.codes.length, 0);
      },
    );

    test('a notification that fails to show keeps nothing', () async {
      plugin.failShow = true;
      await service.init();

      await expectLater(
        service.show(
          const RelayNotification(title: 'OTP from Bank', body: '1', code: '1'),
        ),
        throwsStateError,
      );
      expect(service.codes.length, 0);
    });
  });
}

class _Shown {
  _Shown(this.id, this.details, this.payload);

  final int id;
  final NotificationDetails? details;
  final String? payload;
}

/// Stands in for the plugin where the platform side isn't a method channel
/// (Linux talks D-Bus).
class _FakePlugin implements FlutterLocalNotificationsPlugin {
  final List<_Shown> shown = [];
  DidReceiveNotificationResponseCallback? respond;
  NotificationResponse? launchResponse;
  bool failShow = false;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    respond = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  Future<NotificationAppLaunchDetails?>
  getNotificationAppLaunchDetails() async {
    final response = launchResponse;
    if (response == null) return null;
    return NotificationAppLaunchDetails(true, notificationResponse: response);
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    if (failShow) throw StateError('no notification server');
    shown.add(_Shown(id, notificationDetails, payload));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
