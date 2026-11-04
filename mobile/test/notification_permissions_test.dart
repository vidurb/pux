import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/delivery_prompts.dart';
import 'package:pux/src/screens/home_screen.dart';
import 'package:pux/src/services/background_restrictions.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/notification_permissions.dart';
import 'package:pux/src/services/record_store.dart';

const _offTitle = 'Notifications are off';
const _channelTitle = 'OTP code notifications are off';
const _quietTitle = 'Codes may arrive without an alert';
const _hibernationTitle = 'Keep codes arriving when you rarely open pux';

const _pluginChannel = MethodChannel('dexterous.com/flutter/local_notifications');

/// MainActivity's side of the notification channel.
class _FakeAndroid {
  bool appEnabled = true;
  bool? channelEnabled = true;
  bool settingsOpen = true;
  Object? statusError;
  final calls = <String>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      NotificationPermissions.channel,
      (call) async {
        calls.add(call.method);
        if (call.method != 'getStatus') return settingsOpen;
        if (statusError != null) throw statusError!;
        return {'appEnabled': appEnabled, 'channelEnabled': channelEnabled};
      },
    );
  }

  Iterable<String> get opened => calls.where((call) => call != 'getStatus');
}

/// flutter_local_notifications' native side on iOS and macOS, with the fields
/// each native plugin derives from UNNotificationSettings.
class _FakeApple {
  Map<String, bool> options = authorized;
  bool settingsOpen = true;
  Object? statusError;
  final calls = <String>[];

  static const authorized = {'isEnabled': true, 'isAlertEnabled': true};
  static const denied = {'isEnabled': false, 'isAlertEnabled': false};
  static const provisional = {
    'isEnabled': false,
    'isProvisionalEnabled': true,
    'isAlertEnabled': true,
  };
  static const authorizedAlertsOff = {'isEnabled': true, 'isAlertEnabled': false};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      _pluginChannel,
      (call) async {
        calls.add(call.method);
        if (call.method == 'openAppNotificationSettings') return settingsOpen;
        if (statusError != null) throw statusError!;
        return options;
      },
    );
  }
}

void main() {
  late _FakeAndroid android;
  late _FakeApple apple;
  late List<String> restrictionCalls;
  String hibernation = 'off';

  setUp(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    android = _FakeAndroid()..install();
    apple = _FakeApple()..install();
    restrictionCalls = [];
    hibernation = 'off';
    messenger.setMockMethodCallHandler(BackgroundRestrictions.channel, (call) async {
      restrictionCalls.add(call.method);
      if (call.method != 'getStatus') return true;
      return {'hibernation': hibernation, 'backgroundRestricted': false};
    });
    FlutterSecureStorage.setMockInitialValues({});
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
    NotificationPermissions.instance.access.value = NotificationAccess.allowed;
    IOSFlutterLocalNotificationsPlugin.registerWith();
  });

  tearDown(() {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NotificationPermissions.channel, null);
    messenger.setMockMethodCallHandler(_pluginChannel, null);
    messenger.setMockMethodCallHandler(BackgroundRestrictions.channel, null);
  });

  Future<void> pumpPrompts(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: DeliveryPrompts())));
    await tester.pumpAndSettle();
  }

  Future<void> resume(WidgetTester tester) async {
    // AppLifecycleListener only accepts the transitions a real app goes through.
    for (final state in const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    await tester.pumpAndSettle();
  }

  group('Android', () {
    const cases = <(bool, bool?, String?, String?)>[
      (true, true, null, null),
      // Before Android 8, or before the first code has created the channel.
      (true, null, null, null),
      (false, true, _offTitle, 'openNotificationSettings'),
      (false, null, _offTitle, 'openNotificationSettings'),
      // The channel page is greyed out while the app's notifications are off.
      (false, false, _offTitle, 'openNotificationSettings'),
      (true, false, _channelTitle, 'openChannelSettings'),
    ];

    for (final (app, channel, title, page) in cases) {
      testWidgets('app=$app channel=$channel shows ${title ?? 'nothing'}', (tester) async {
        android.appEnabled = app;
        android.channelEnabled = channel;

        await pumpPrompts(tester);

        if (title == null) {
          expect(find.text('Open settings'), findsNothing);
          return;
        }
        expect(find.text(title), findsOneWidget);
        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();
        expect(android.opened, [page]);
        expect(find.byType(SnackBar), findsNothing);
      });
    }

    testWidgets('a missing channel shows nothing', (tester) async {
      android.statusError = MissingPluginException();

      await pumpPrompts(tester);

      expect(find.text('Open settings'), findsNothing);
    });

    testWidgets('never touches the plugin channel', (tester) async {
      android.appEnabled = false;

      await pumpPrompts(tester);

      expect(apple.calls, isEmpty);
    });
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    group(platform.name, () {
      setUp(() {
        if (platform == TargetPlatform.macOS) {
          MacOSFlutterLocalNotificationsPlugin.registerWith();
        }
      });

      final variant = TargetPlatformVariant.only(platform);

      const cases = <String, (Map<String, bool>, String?)>{
        'authorized': (_FakeApple.authorized, null),
        'denied or not determined': (_FakeApple.denied, _offTitle),
        'provisional': (_FakeApple.provisional, _quietTitle),
        'authorized with alerts off': (_FakeApple.authorizedAlertsOff, _quietTitle),
      };

      cases.forEach((name, expected) {
        final (options, title) = expected;

        testWidgets('$name shows ${title ?? 'nothing'}', (tester) async {
          apple.options = options;

          await pumpPrompts(tester);

          if (title == null) {
            expect(find.text('Open settings'), findsNothing);
          } else {
            expect(find.text(title), findsOneWidget);
          }
        }, variant: variant);
      });

      testWidgets('the button opens the app notification page', (tester) async {
        apple.options = _FakeApple.denied;
        await pumpPrompts(tester);

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(apple.calls, contains('openAppNotificationSettings'));
        expect(android.calls, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
      }, variant: variant);

      testWidgets('the prompt goes away on resume once allowed', (tester) async {
        apple.options = _FakeApple.denied;
        await pumpPrompts(tester);

        apple.options = _FakeApple.authorized;
        await resume(tester);

        expect(find.text(_offTitle), findsNothing);
      }, variant: variant);

      testWidgets('a provisional state that becomes authorized clears', (tester) async {
        apple.options = _FakeApple.provisional;
        await pumpPrompts(tester);
        expect(find.text(_quietTitle), findsOneWidget);

        apple.options = _FakeApple.authorized;
        await resume(tester);

        expect(find.text(_quietTitle), findsNothing);
      }, variant: variant);

      testWidgets('no prompt of this kind can be dismissed', (tester) async {
        apple.options = _FakeApple.provisional;
        await pumpPrompts(tester);

        expect(find.text('Dismiss'), findsNothing);
      }, variant: variant);

      testWidgets('says so if settings would not open', (tester) async {
        apple.options = _FakeApple.denied;
        apple.settingsOpen = false;
        await pumpPrompts(tester);

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(find.textContaining("Couldn't open settings"), findsOneWidget);
      }, variant: variant);

      testWidgets('a failed check shows nothing at first', (tester) async {
        apple.statusError = PlatformException(code: 'boom');

        await pumpPrompts(tester);

        expect(find.text('Open settings'), findsNothing);
      }, variant: variant);
    });
  }

  for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
    testWidgets('${platform.name} checks nothing and shows nothing', (tester) async {
      android.appEnabled = false;
      apple.options = _FakeApple.denied;

      await pumpPrompts(tester);

      expect(android.calls, isEmpty);
      expect(apple.calls, isEmpty);
      expect(find.text('Open settings'), findsNothing);
    }, variant: TargetPlatformVariant.only(platform));
  }

  group('state on resume', () {
    testWidgets('appears when notifications are turned off while away', (tester) async {
      await pumpPrompts(tester);
      expect(find.text(_offTitle), findsNothing);

      android.appEnabled = false;
      await resume(tester);

      expect(find.text(_offTitle), findsOneWidget);
    });

    testWidgets('goes away once allowed, and the channel prompt takes over', (tester) async {
      android.appEnabled = false;
      android.channelEnabled = false;
      await pumpPrompts(tester);
      expect(find.text(_offTitle), findsOneWidget);

      await resume(tester);
      expect(find.text(_offTitle), findsOneWidget, reason: 'setting not changed yet');

      android.appEnabled = true;
      await resume(tester);
      expect(find.text(_offTitle), findsNothing);
      expect(find.text(_channelTitle), findsOneWidget);

      android.channelEnabled = true;
      await resume(tester);
      expect(find.text(_channelTitle), findsNothing);
    });

    testWidgets('a failed check keeps a warning already showing', (tester) async {
      android.appEnabled = false;
      await pumpPrompts(tester);

      android.statusError = PlatformException(code: 'boom');
      await resume(tester);

      expect(find.text(_offTitle), findsOneWidget);
    });
  });

  group('dismissal and order', () {
    testWidgets('notifications off offers no way to dismiss it', (tester) async {
      android.appEnabled = false;
      await pumpPrompts(tester);

      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Dismiss'), findsNothing);
    });

    testWidgets('it stays across restarts', (tester) async {
      android.appEnabled = false;
      await pumpPrompts(tester);
      await pumpPrompts(tester);

      expect(find.text(_offTitle), findsOneWidget);
    });

    testWidgets('it replaces other prompts, which return once it is fixed', (tester) async {
      android.appEnabled = false;
      hibernation = 'hibernation';
      await pumpPrompts(tester);

      expect(find.text(_offTitle), findsOneWidget);
      expect(find.text(_hibernationTitle), findsNothing);
      expect(find.text('Open settings'), findsOneWidget);

      android.appEnabled = true;
      await resume(tester);

      expect(find.text(_offTitle), findsNothing);
      expect(find.text(_hibernationTitle), findsOneWidget);
    });

    testWidgets('its button opens notification settings, not a restriction page', (tester) async {
      android.appEnabled = false;
      hibernation = 'hibernation';
      await pumpPrompts(tester);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      expect(android.opened, ['openNotificationSettings']);
      expect(restrictionCalls.where((call) => call != 'getStatus'), isEmpty);
    });

    testWidgets('it does not disturb a dismissed restriction', (tester) async {
      hibernation = 'hibernation';
      await pumpPrompts(tester);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      android.appEnabled = false;
      await resume(tester);
      expect(find.text(_offTitle), findsOneWidget);

      android.appEnabled = true;
      await resume(tester);
      expect(find.text(_offTitle), findsNothing);
      expect(find.text(_hibernationTitle), findsNothing);
    });
  });

  group('the request flow', () {
    test('a granted reply is not believed over what the OS reports', () async {
      android.appEnabled = false;

      await NotificationPermissions.instance.request(() async => 'granted');

      expect(NotificationPermissions.instance.access.value, NotificationAccess.off);
    });

    test('a denied reply is not believed over what the OS reports', () async {
      await NotificationPermissions.instance.request(() async => 'denied');

      expect(NotificationPermissions.instance.access.value, NotificationAccess.allowed);
    });

    test('checks only after the request has finished', () async {
      android.appEnabled = false;

      await NotificationPermissions.instance.request(() async {
        expect(android.calls, isEmpty);
        android.appEnabled = true;
        return null;
      });

      expect(android.calls, ['getStatus']);
      expect(NotificationPermissions.instance.access.value, NotificationAccess.allowed);
    });

    test('a failed request still checks, and does not throw', () async {
      android.appEnabled = false;

      await NotificationPermissions.instance.request(
        () async => throw PlatformException(code: 'request-in-progress'),
      );

      expect(NotificationPermissions.instance.access.value, NotificationAccess.off);
    });

    testWidgets('an answer that arrives while the home screen shows updates it', (tester) async {
      await pumpPrompts(tester);
      expect(find.text(_offTitle), findsNothing);

      android.appEnabled = false;
      await tester.runAsync(() => NotificationPermissions.instance.request(() async => null));
      await tester.pumpAndSettle();

      expect(find.text(_offTitle), findsOneWidget);
    });
  });

  group('the home screen', () {
    tearDown(() {
      DeliveryController.instance.status.value = const DeliveryStatus(DeliveryState.idle);
    });

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: HomeScreen())));
      await tester.pumpAndSettle();
    }

    testWidgets('warns even though delivery is ready', (tester) async {
      android.appEnabled = false;
      DeliveryController.instance.status.value = const DeliveryStatus(DeliveryState.ready);

      await pumpHome(tester);

      expect(DeliveryController.instance.status.value.state, DeliveryState.ready);
      expect(find.text(_offTitle), findsOneWidget);
    });

    testWidgets('puts it above a delivery problem, and keeps both usable', (tester) async {
      android.appEnabled = false;
      DeliveryController.instance.status.value = const DeliveryStatus(
        DeliveryState.retrying,
        message: 'offline',
      );

      await pumpHome(tester);

      final warning = tester.getTopLeft(find.text(_offTitle));
      final delivery = tester.getTopLeft(find.textContaining('Not connected'));
      expect(warning.dy, lessThan(delivery.dy));
      expect(find.text('Retry now'), findsOneWidget);
    });

    testWidgets('shows nothing extra when notifications are allowed', (tester) async {
      DeliveryController.instance.status.value = const DeliveryStatus(DeliveryState.ready);

      await pumpHome(tester);

      expect(find.text('Open settings'), findsNothing);
    });
  });
}
