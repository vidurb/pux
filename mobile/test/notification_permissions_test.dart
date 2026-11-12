import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/delivery_prompts.dart';
import 'package:pux/src/screens/home_screen.dart';
import 'package:pux/src/screens/notification_explainer.dart';
import 'package:pux/src/services/background_restrictions.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/notification_permissions.dart';
import 'package:pux/src/services/record_store.dart';

const _offTitle = 'Notifications are off';
const _channelTitle = 'OTP code notifications are off';
const _quietTitle = 'Codes may arrive without an alert';
const _hibernationTitle = 'Keep codes arriving when you rarely open pux';
const _quietChannelTitle = "Codes don't pop up on screen";
const _summaryTitle = 'Codes wait for your notification summary';
const _explainerTitle = 'Allow notifications to see your codes';

const _pluginChannel = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);

/// The app's side of the notification channel: MainActivity on Android, and
/// AppDelegate (iOS) or MainFlutterWindow (macOS) for `getAuthorizationStatus`.
class _FakeAndroid {
  bool appEnabled = true;
  bool? channelEnabled = true;

  /// The Android 13+ runtime permission: null before Android 13.
  String? permission;

  /// What iOS and macOS report as UNAuthorizationStatus. Anything but
  /// "notDetermined" leaves the answer to the plugin's checkPermissions.
  String appleStatus = 'authorized';
  bool? channelQuiet = false;
  bool? scheduledSummary = false;
  bool settingsOpen = true;
  Object? statusError;
  final calls = <String>[];

  static const _reads = {'getStatus', 'getAuthorizationStatus'};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(NotificationPermissions.channel, (
          call,
        ) async {
          calls.add(call.method);
          if (!_reads.contains(call.method)) return settingsOpen;
          if (statusError != null) throw statusError!;
          if (call.method == 'getAuthorizationStatus') return appleStatus;
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            return {'scheduledSummary': scheduledSummary};
          }
          return {
            'appEnabled': appEnabled,
            'channelEnabled': channelEnabled,
            'channelQuiet': channelQuiet,
            'permission': permission,
          };
        });
  }

  Iterable<String> get opened => calls.where((call) => !_reads.contains(call));
}

/// flutter_local_notifications' native side on iOS and macOS, with the fields
/// each native plugin derives from UNNotificationSettings.
///
/// It's also where Android's requestNotificationsPermission goes, as every
/// platform's plugin shares the channel.
class _FakeApple {
  Map<String, bool> options = authorized;
  bool settingsOpen = true;
  Object? statusError;
  final calls = <MethodCall>[];

  /// Plays the system prompt, returning the plugin's reply.
  Object? Function()? onRequest;

  static const _requests = {
    'requestPermissions',
    'requestNotificationsPermission',
  };

  static const authorized = {'isEnabled': true, 'isAlertEnabled': true};
  static const denied = {'isEnabled': false, 'isAlertEnabled': false};
  static const provisional = {
    'isEnabled': false,
    'isProvisionalEnabled': true,
    'isAlertEnabled': true,
  };
  static const authorizedAlertsOff = {
    'isEnabled': true,
    'isAlertEnabled': false,
  };

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pluginChannel, (call) async {
          calls.add(call);
          if (call.method == 'openAppNotificationSettings') return settingsOpen;
          if (_requests.contains(call.method)) {
            return onRequest?.call() ?? false;
          }
          if (statusError != null) throw statusError!;
          return options;
        });
  }

  Iterable<String> get methods => calls.map((call) => call.method);

  Iterable<MethodCall> get requests =>
      calls.where((call) => _requests.contains(call.method));
}

void main() {
  late _FakeAndroid android;
  late _FakeApple apple;
  late List<String> restrictionCalls;
  String hibernation = 'off';

  setUp(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    android = _FakeAndroid()..install();
    apple = _FakeApple()..install();
    restrictionCalls = [];
    hibernation = 'off';
    messenger.setMockMethodCallHandler(BackgroundRestrictions.channel, (
      call,
    ) async {
      restrictionCalls.add(call.method);
      if (call.method != 'getStatus') return true;
      return {'hibernation': hibernation, 'backgroundRestricted': false};
    });
    FlutterSecureStorage.setMockInitialValues({});
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
    NotificationPermissions.instance.access.value = NotificationAccess.allowed;
    NotificationPermissions.instance.quietDelivery.value =
        const DeliveryRestrictionStatus();
    IOSFlutterLocalNotificationsPlugin.registerWith();
  });

  tearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(NotificationPermissions.channel, null);
    messenger.setMockMethodCallHandler(_pluginChannel, null);
    messenger.setMockMethodCallHandler(BackgroundRestrictions.channel, null);
  });

  Future<void> pumpPrompts(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: DeliveryPrompts())),
    );
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
      testWidgets('app=$app channel=$channel shows ${title ?? 'nothing'}', (
        tester,
      ) async {
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
        'authorized with alerts off': (
          _FakeApple.authorizedAlertsOff,
          _quietTitle,
        ),
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

      testWidgets('the off prompt says what happens to codes here', (
        tester,
      ) async {
        apple.options = _FakeApple.denied;

        await pumpPrompts(tester);

        final desktop = platform == TargetPlatform.macOS;
        expect(
          find.textContaining('New codes wait on this screen'),
          desktop ? findsOneWidget : findsNothing,
        );
        expect(
          find.textContaining('are lost'),
          desktop ? findsNothing : findsOneWidget,
        );
      }, variant: variant);

      testWidgets('the button opens the app notification page', (tester) async {
        apple.options = _FakeApple.denied;
        await pumpPrompts(tester);

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(apple.methods, contains('openAppNotificationSettings'));
        expect(android.opened, isEmpty);
        expect(find.byType(SnackBar), findsNothing);
      }, variant: variant);

      testWidgets('the prompt goes away on resume once allowed', (
        tester,
      ) async {
        apple.options = _FakeApple.denied;
        await pumpPrompts(tester);

        apple.options = _FakeApple.authorized;
        await resume(tester);

        expect(find.text(_offTitle), findsNothing);
      }, variant: variant);

      testWidgets('a provisional state that becomes authorized clears', (
        tester,
      ) async {
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
    testWidgets('${platform.name} checks nothing and shows nothing', (
      tester,
    ) async {
      android.appEnabled = false;
      android.permission = 'notGranted';
      android.appleStatus = 'notDetermined';
      apple.options = _FakeApple.denied;

      await pumpPrompts(tester);

      expect(android.calls, isEmpty);
      expect(apple.calls, isEmpty);
      expect(find.text('Open settings'), findsNothing);
      expect(find.text(_explainerTitle), findsNothing);
    }, variant: TargetPlatformVariant.only(platform));
  }

  group('check', () {
    test('returns what it read', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      android.appEnabled = false;

      expect(
        await NotificationPermissions.instance.check(),
        NotificationAccess.off,
      );
      expect(
        NotificationPermissions.instance.access.value,
        NotificationAccess.off,
      );
    });

    test('returns null on failure, keeping the last state', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      android.appEnabled = false;
      await NotificationPermissions.instance.check();
      android.statusError = PlatformException(code: 'boom');

      expect(await NotificationPermissions.instance.check(), isNull);
      expect(
        NotificationPermissions.instance.access.value,
        NotificationAccess.off,
      );
    });

    test('returns null if the OS never answers', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            NotificationPermissions.channel,
            (_) => Completer<Object?>().future,
          );

      expect(
        await NotificationPermissions.instance.check(
          timeout: const Duration(milliseconds: 5),
        ),
        isNull,
      );
    });

    test('returns null if the answer is malformed', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            NotificationPermissions.channel,
            (_) async => {'appEnabled': 'yes'},
          );

      expect(await NotificationPermissions.instance.check(), isNull);
    });

    for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
      test('has nothing to read on ${platform.name}', () async {
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);

        expect(
          await NotificationPermissions.instance.check(),
          NotificationAccess.allowed,
        );
      });
    }
  });

  group('state on resume', () {
    testWidgets('appears when notifications are turned off while away', (
      tester,
    ) async {
      await pumpPrompts(tester);
      expect(find.text(_offTitle), findsNothing);

      android.appEnabled = false;
      await resume(tester);

      expect(find.text(_offTitle), findsOneWidget);
    });

    testWidgets('goes away once allowed, and the channel prompt takes over', (
      tester,
    ) async {
      android.appEnabled = false;
      android.channelEnabled = false;
      await pumpPrompts(tester);
      expect(find.text(_offTitle), findsOneWidget);

      await resume(tester);
      expect(
        find.text(_offTitle),
        findsOneWidget,
        reason: 'setting not changed yet',
      );

      android.appEnabled = true;
      await resume(tester);
      expect(find.text(_offTitle), findsNothing);
      expect(find.text(_channelTitle), findsOneWidget);

      android.channelEnabled = true;
      await resume(tester);
      expect(find.text(_channelTitle), findsNothing);
    });

    testWidgets('a failed check keeps a warning already showing', (
      tester,
    ) async {
      android.appEnabled = false;
      await pumpPrompts(tester);

      android.statusError = PlatformException(code: 'boom');
      await resume(tester);

      expect(find.text(_offTitle), findsOneWidget);
    });
  });

  group('dismissal and order', () {
    testWidgets('notifications off offers no way to dismiss it', (
      tester,
    ) async {
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

    testWidgets('it replaces other prompts, which return once it is fixed', (
      tester,
    ) async {
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

    testWidgets(
      'its button opens notification settings, not a restriction page',
      (tester) async {
        android.appEnabled = false;
        hibernation = 'hibernation';
        await pumpPrompts(tester);

        await tester.tap(find.text('Open settings'));
        await tester.pumpAndSettle();

        expect(android.opened, ['openNotificationSettings']);
        expect(restrictionCalls.where((call) => call != 'getStatus'), isEmpty);
      },
    );

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

  group('a quiet Android channel', () {
    const cases = <bool?, bool>{true: true, false: false, null: false};

    cases.forEach((quiet, prompts) {
      testWidgets(
        'channelQuiet=$quiet ${prompts ? 'prompts' : 'does not prompt'}',
        (tester) async {
          android.channelQuiet = quiet;

          await pumpPrompts(tester);

          expect(
            find.text(_quietChannelTitle),
            prompts ? findsOneWidget : findsNothing,
          );
        },
      );
    });

    testWidgets('opens the channel page', (tester) async {
      android.channelQuiet = true;
      await pumpPrompts(tester);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      expect(android.opened, ['openChannelSettings']);
      expect(restrictionCalls.where((call) => call != 'getStatus'), isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('says so if settings would not open', (tester) async {
      android.channelQuiet = true;
      android.settingsOpen = false;
      await pumpPrompts(tester);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't open settings"), findsOneWidget);
    });

    testWidgets('waits behind notifications being off', (tester) async {
      android.appEnabled = false;
      android.channelQuiet = true;
      await pumpPrompts(tester);

      expect(find.text(_offTitle), findsOneWidget);
      expect(find.text(_quietChannelTitle), findsNothing);
    });

    testWidgets('waits behind a restriction that stops codes', (tester) async {
      hibernation = 'hibernation';
      android.channelQuiet = true;
      await pumpPrompts(tester);

      expect(find.text(_hibernationTitle), findsOneWidget);
      expect(find.text(_quietChannelTitle), findsNothing);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      expect(find.text(_quietChannelTitle), findsOneWidget);
    });

    testWidgets('goes away on resume once the channel alerts again', (
      tester,
    ) async {
      android.channelQuiet = true;
      await pumpPrompts(tester);

      android.channelQuiet = false;
      await resume(tester);

      expect(find.text(_quietChannelTitle), findsNothing);
    });

    testWidgets('dismissing stays dismissed across resumes and restarts', (
      tester,
    ) async {
      android.channelQuiet = true;
      await pumpPrompts(tester);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text(_quietChannelTitle), findsNothing);

      await resume(tester);
      expect(find.text(_quietChannelTitle), findsNothing);

      await pumpPrompts(tester);
      expect(find.text(_quietChannelTitle), findsNothing);
    });

    testWidgets('a dismissal is forgotten once the channel alerts again', (
      tester,
    ) async {
      android.channelQuiet = true;
      await pumpPrompts(tester);
      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();

      android.channelQuiet = false;
      await resume(tester);
      expect(await RecordStore.instance.dismissedRestrictionPrompts(), isEmpty);

      android.channelQuiet = true;
      await resume(tester);
      expect(find.text(_quietChannelTitle), findsOneWidget);
    });

    testWidgets('a failed check keeps the hint and the dismissals', (
      tester,
    ) async {
      android.channelQuiet = true;
      await pumpPrompts(tester);

      android.statusError = PlatformException(code: 'boom');
      await resume(tester);
      expect(find.text(_quietChannelTitle), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await resume(tester);
      expect(await RecordStore.instance.dismissedRestrictionPrompts(), {
        'quietChannel',
      });
    });

    test('check reports it', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      android.channelQuiet = true;

      await NotificationPermissions.instance.check();

      final quiet = NotificationPermissions.instance.quietDelivery.value;
      expect(quiet.active, {DeliveryRestriction.quietChannel});
      expect(quiet.clear, isEmpty);
    });
  });

  group('the iOS scheduled summary', () {
    final ios = TargetPlatformVariant.only(TargetPlatform.iOS);

    testWidgets('prompts while pux is in the summary', (tester) async {
      android.scheduledSummary = true;

      await pumpPrompts(tester);

      expect(find.text(_summaryTitle), findsOneWidget);
      expect(find.text('Dismiss'), findsOneWidget);
    }, variant: ios);

    testWidgets('shows nothing for immediate delivery', (tester) async {
      await pumpPrompts(tester);

      expect(find.text(_summaryTitle), findsNothing);
      // Only reads: the explainer's check reads the state again.
      expect(android.calls.toSet(), {'getStatus', 'getAuthorizationStatus'});
    }, variant: ios);

    testWidgets('opens the app notification page', (tester) async {
      android.scheduledSummary = true;
      await pumpPrompts(tester);

      await tester.tap(find.text('Open settings'));
      await tester.pumpAndSettle();

      expect(apple.methods, contains('openAppNotificationSettings'));
      expect(android.opened, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
    }, variant: ios);

    testWidgets('waits behind notifications that arrive quietly', (
      tester,
    ) async {
      android.scheduledSummary = true;
      apple.options = _FakeApple.provisional;
      await pumpPrompts(tester);

      expect(find.text(_quietTitle), findsOneWidget);
      expect(find.text(_summaryTitle), findsNothing);

      apple.options = _FakeApple.authorized;
      await resume(tester);

      expect(find.text(_summaryTitle), findsOneWidget);
    }, variant: ios);

    testWidgets('goes away on resume once delivery is immediate', (
      tester,
    ) async {
      android.scheduledSummary = true;
      await pumpPrompts(tester);

      android.scheduledSummary = false;
      await resume(tester);

      expect(find.text(_summaryTitle), findsNothing);
    }, variant: ios);

    testWidgets('dismissing stays dismissed across resumes and restarts', (
      tester,
    ) async {
      android.scheduledSummary = true;
      await pumpPrompts(tester);

      await tester.tap(find.text('Dismiss'));
      await tester.pumpAndSettle();
      await resume(tester);
      await pumpPrompts(tester);

      expect(find.text(_summaryTitle), findsNothing);
      expect(await RecordStore.instance.dismissedRestrictionPrompts(), {
        'scheduledSummary',
      });
    }, variant: ios);

    testWidgets('a missing channel still reads notification access', (
      tester,
    ) async {
      android.statusError = MissingPluginException();
      apple.options = _FakeApple.denied;

      await pumpPrompts(tester);

      expect(find.text(_offTitle), findsOneWidget);
    }, variant: ios);

    testWidgets('macOS never asks about the summary', (tester) async {
      MacOSFlutterLocalNotificationsPlugin.registerWith();
      android.scheduledSummary = true;

      await pumpPrompts(tester);

      // macOS asks the channel only whether the user has been asked yet.
      expect(android.calls, isNot(contains('getStatus')));
      expect(find.text('Open settings'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('the request flow', () {
    test('a granted reply is not believed over what the OS reports', () async {
      android.appEnabled = false;

      await NotificationPermissions.instance.request(() async => 'granted');

      expect(
        NotificationPermissions.instance.access.value,
        NotificationAccess.off,
      );
    });

    test('a denied reply is not believed over what the OS reports', () async {
      await NotificationPermissions.instance.request(() async => 'denied');

      expect(
        NotificationPermissions.instance.access.value,
        NotificationAccess.allowed,
      );
    });

    test('checks only after the request has finished', () async {
      android.appEnabled = false;

      await NotificationPermissions.instance.request(() async {
        expect(android.calls, isEmpty);
        android.appEnabled = true;
        return null;
      });

      expect(android.calls, ['getStatus']);
      expect(
        NotificationPermissions.instance.access.value,
        NotificationAccess.allowed,
      );
    });

    test('a failed request still checks, and does not throw', () async {
      android.appEnabled = false;

      await NotificationPermissions.instance.request(
        () async => throw PlatformException(code: 'request-in-progress'),
      );

      expect(
        NotificationPermissions.instance.access.value,
        NotificationAccess.off,
      );
    });

    testWidgets(
      'an answer that arrives while the home screen shows updates it',
      (tester) async {
        await pumpPrompts(tester);
        expect(find.text(_offTitle), findsNothing);

        android.appEnabled = false;
        await tester.runAsync(
          () => NotificationPermissions.instance.request(() async => null),
        );
        await tester.pumpAndSettle();

        expect(find.text(_offTitle), findsOneWidget);
      },
    );
  });

  group('the home screen', () {
    tearDown(() {
      DeliveryController.instance.status.value = const DeliveryStatus(
        DeliveryState.idle,
      );
    });

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: HomeScreen())),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('warns even though delivery is ready', (tester) async {
      android.appEnabled = false;
      DeliveryController.instance.status.value = const DeliveryStatus(
        DeliveryState.ready,
      );

      await pumpHome(tester);

      expect(
        DeliveryController.instance.status.value.state,
        DeliveryState.ready,
      );
      expect(find.text(_offTitle), findsOneWidget);
    });

    testWidgets('puts it above a delivery problem, and keeps both usable', (
      tester,
    ) async {
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

    testWidgets('shows nothing extra when notifications are allowed', (
      tester,
    ) async {
      DeliveryController.instance.status.value = const DeliveryStatus(
        DeliveryState.ready,
      );

      await pumpHome(tester);

      expect(find.text('Open settings'), findsNothing);
    });
  });

  group('never asked', () {
    group('on Android 13+', () {
      setUp(() {
        AndroidFlutterLocalNotificationsPlugin.registerWith();
        android.appEnabled = false;
        android.permission = 'notGranted';
      });

      Future<NotificationAccess?> checkAndroid() async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        return NotificationPermissions.instance.check();
      }

      test('a permission pux never asked for reads as not asked', () async {
        expect(await checkAndroid(), NotificationAccess.notAsked);
      });

      test('once pux has asked, the same answer is a denial', () async {
        FlutterSecureStorage.setMockInitialValues({
          'notification_permission_asked': 'true',
        });

        expect(await checkAndroid(), NotificationAccess.off);
      });

      test('a permission denied once is a denial', () async {
        android.permission = 'denied';

        expect(await checkAndroid(), NotificationAccess.off);
      });

      test(
        'notifications switched off with the permission granted are off',
        () async {
          android.permission = 'granted';

          expect(await checkAndroid(), NotificationAccess.off);
        },
      );

      test('before Android 13 there is nothing to ask', () async {
        android.permission = null;

        expect(await checkAndroid(), NotificationAccess.off);
      });

      test('ask shows the system prompt and records it', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        apple.onRequest = () {
          android.appEnabled = true;
          android.permission = 'granted';
          return true;
        };

        await NotificationPermissions.instance.ask();

        expect(apple.requests.single.method, 'requestNotificationsPermission');
        expect(
          NotificationPermissions.instance.access.value,
          NotificationAccess.allowed,
        );
        expect(
          await RecordStore.instance.notificationPermissionAsked(),
          isTrue,
        );
      });

      test('a denial in the system prompt then reads as off', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        apple.onRequest = () => false;

        await NotificationPermissions.instance.ask();

        expect(
          NotificationPermissions.instance.access.value,
          NotificationAccess.off,
        );
      });

      test('a failed request records nothing', () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        apple.onRequest = () =>
            throw PlatformException(code: 'permissionRequestInProgress');

        await NotificationPermissions.instance.ask();

        expect(
          await RecordStore.instance.notificationPermissionAsked(),
          isFalse,
        );
        expect(
          NotificationPermissions.instance.access.value,
          NotificationAccess.notAsked,
        );
      });
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      group('on ${platform.name}', () {
        setUp(() {
          if (platform == TargetPlatform.macOS) {
            MacOSFlutterLocalNotificationsPlugin.registerWith();
          }
          android.appleStatus = 'notDetermined';
          apple.options = _FakeApple.denied;
        });

        Future<NotificationAccess?> checkApple() async {
          debugDefaultTargetPlatformOverride = platform;
          addTearDown(() => debugDefaultTargetPlatformOverride = null);
          return NotificationPermissions.instance.check();
        }

        test('not determined reads as not asked', () async {
          expect(await checkApple(), NotificationAccess.notAsked);
        });

        test('denied reads as off, as it did when startup asked', () async {
          android.appleStatus = 'denied';

          expect(await checkApple(), NotificationAccess.off);
        });

        test('without the app channel, not determined reads as off', () async {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(NotificationPermissions.channel, null);

          expect(await checkApple(), NotificationAccess.off);
        });

        test(
          'ask requests alerts, badges and sounds, recording nothing',
          () async {
            debugDefaultTargetPlatformOverride = platform;
            addTearDown(() => debugDefaultTargetPlatformOverride = null);
            apple.onRequest = () {
              android.appleStatus = 'authorized';
              apple.options = _FakeApple.authorized;
              return true;
            };

            await NotificationPermissions.instance.ask();

            final request = apple.requests.single;
            expect(request.method, 'requestPermissions');
            expect(request.arguments, containsPair('alert', true));
            expect(request.arguments, containsPair('badge', true));
            expect(request.arguments, containsPair('sound', true));
            expect(
              NotificationPermissions.instance.access.value,
              NotificationAccess.allowed,
            );
            expect(
              await RecordStore.instance.notificationPermissionAsked(),
              isFalse,
            );
          },
        );
      });
    }
  });

  group('the explainer', () {
    setUp(() {
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      android.appEnabled = false;
      android.permission = 'notGranted';
    });

    void grantOnRequest() {
      apple.onRequest = () {
        android.appEnabled = true;
        android.permission = 'granted';
        android.appleStatus = 'authorized';
        apple.options = _FakeApple.authorized;
        return true;
      };
    }

    void denyOnRequest() {
      apple.onRequest = () {
        android.appleStatus = 'denied';
        return false;
      };
    }

    testWidgets('opens before the system prompt when it has never asked', (
      tester,
    ) async {
      await pumpPrompts(tester);

      expect(find.text(_explainerTitle), findsOneWidget);
      expect(find.textContaining('Nothing else is sent'), findsOneWidget);
      expect(apple.requests, isEmpty);
    });

    testWidgets(
      'Continue shows the system prompt, and an allowed answer clears all',
      (tester) async {
        grantOnRequest();
        await pumpPrompts(tester);

        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(apple.requests, hasLength(1));
        expect(find.text(_explainerTitle), findsNothing);
        expect(find.text(_offTitle), findsNothing);
      },
    );

    testWidgets('a denial leaves the prompt that opens settings', (
      tester,
    ) async {
      denyOnRequest();
      await pumpPrompts(tester);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text(_explainerTitle), findsNothing);
      expect(find.text(_offTitle), findsOneWidget);
      expect(find.text('Open settings'), findsOneWidget);
      expect(find.text('Allow notifications'), findsNothing);
    });

    testWidgets(
      'Not now asks nothing, and the prompt then asks instead of opening settings',
      (tester) async {
        await pumpPrompts(tester);

        await tester.tap(find.text('Not now'));
        await tester.pumpAndSettle();

        expect(apple.requests, isEmpty);
        expect(find.text(_explainerTitle), findsNothing);
        expect(find.text(_offTitle), findsOneWidget);
        expect(find.text('Open settings'), findsNothing);

        grantOnRequest();
        await tester.tap(find.text('Allow notifications'));
        await tester.pumpAndSettle();

        expect(apple.requests, hasLength(1));
        expect(android.opened, isEmpty);
        expect(find.text(_offTitle), findsNothing);
      },
    );

    testWidgets('after Not now it does not open by itself again', (
      tester,
    ) async {
      await pumpPrompts(tester);
      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      await pumpPrompts(tester);

      expect(find.text(_explainerTitle), findsNothing);
      expect(find.text('Allow notifications'), findsOneWidget);
    });

    testWidgets('closing it any other way counts as Not now', (tester) async {
      await pumpPrompts(tester);

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(find.text(_explainerTitle), findsNothing);
      expect(await RecordStore.instance.notificationExplainerSkipped(), isTrue);
      expect(apple.requests, isEmpty);
    });

    testWidgets('does not open once pux has asked', (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'notification_permission_asked': 'true',
      });

      await pumpPrompts(tester);

      expect(find.text(_explainerTitle), findsNothing);
      expect(find.text('Open settings'), findsOneWidget);
    });

    testWidgets('does not open when notifications are allowed', (tester) async {
      android.appEnabled = true;
      android.permission = 'granted';

      await pumpPrompts(tester);

      expect(find.text(_explainerTitle), findsNothing);
    });

    testWidgets('does not open if the state cannot be read', (tester) async {
      android.statusError = PlatformException(code: 'boom');

      await pumpPrompts(tester);

      expect(find.text(_explainerTitle), findsNothing);
    });

    testWidgets('opens over the home screen, which is there once it closes', (
      tester,
    ) async {
      FlutterSecureStorage.setMockInitialValues({'inbox': 'token@pux.test'});
      DeliveryController.instance.status.value = const DeliveryStatus(
        DeliveryState.ready,
      );
      addTearDown(
        () => DeliveryController.instance.status.value = const DeliveryStatus(
          DeliveryState.idle,
        ),
      );
      grantOnRequest();

      await tester.pumpWidget(
        const ProviderScope(child: MaterialApp(home: HomeScreen())),
      );
      await tester.pumpAndSettle();
      expect(find.text(_explainerTitle), findsOneWidget);

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.byType(NotificationExplainer), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text(_offTitle), findsNothing);
    });

    for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
      // This group's setUp registered Android's.
      void registerPlugin() => platform == TargetPlatform.iOS
          ? IOSFlutterLocalNotificationsPlugin.registerWith()
          : MacOSFlutterLocalNotificationsPlugin.registerWith();

      testWidgets('on ${platform.name} opens while not determined', (
        tester,
      ) async {
        registerPlugin();
        android.appleStatus = 'notDetermined';
        apple.options = _FakeApple.denied;
        grantOnRequest();

        await pumpPrompts(tester);
        expect(find.text(_explainerTitle), findsOneWidget);
        final desktop = platform == TargetPlatform.macOS;
        expect(
          find.textContaining('wait on the home screen'),
          desktop ? findsOneWidget : findsNothing,
        );

        await tester.tap(find.text('Continue'));
        await tester.pumpAndSettle();

        expect(apple.requests.single.method, 'requestPermissions');
        expect(find.text(_offTitle), findsNothing);
      }, variant: TargetPlatformVariant.only(platform));

      testWidgets(
        'on ${platform.name} an upgrade that was asked at startup sees none',
        (tester) async {
          registerPlugin();
          android.appleStatus = 'denied';
          apple.options = _FakeApple.denied;

          await pumpPrompts(tester);

          expect(find.text(_explainerTitle), findsNothing);
          expect(find.text('Open settings'), findsOneWidget);
        },
        variant: TargetPlatformVariant.only(platform),
      );
    }
  });
}
