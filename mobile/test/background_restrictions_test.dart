import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/delivery_prompts.dart';
import 'package:pux/src/screens/home_screen.dart';
import 'package:pux/src/screens/import_enrollment_screen.dart';
import 'package:pux/src/services/background_restrictions.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/delivery_service.dart';
import 'package:pux/src/services/record_store.dart';

const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _hibernationTitle = 'Keep codes arriving when you rarely open pux';
const _backgroundTitle = 'Background use is restricted';

/// MainActivity's side of the channel.
class _FakeChannel {
  String hibernation = 'off';
  bool? backgroundRestricted = false;
  bool settingsOpen = true;
  Object? statusError;
  final calls = <String>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      BackgroundRestrictions.channel,
      (call) async {
        calls.add(call.method);
        if (call.method != 'getStatus') return settingsOpen;
        if (statusError != null) throw statusError!;
        return {'hibernation': hibernation, 'backgroundRestricted': backgroundRestricted};
      },
    );
  }
}

class _NoDelivery implements DeliveryService {
  @override
  Future<void> init() async {}

  @override
  Future<void> stop() async {}
}

void main() {
  late _FakeChannel native;

  setUp(() {
    native = _FakeChannel()..install();
    // The app does this at startup. The prompts also check notifications on iOS.
    IOSFlutterLocalNotificationsPlugin.registerWith();
    FlutterSecureStorage.setMockInitialValues({});
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      BackgroundRestrictions.channel,
      null,
    );
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

  group('hibernation status', () {
    const cases = {
      'hibernation': true,
      'permissionReset': false,
      'off': false,
      'unavailable': false,
      'unknown': false,
    };

    cases.forEach((status, prompts) {
      testWidgets('$status ${prompts ? 'prompts' : 'does not prompt'}', (tester) async {
        native.hibernation = status;

        await pumpPrompts(tester);

        expect(find.text(_hibernationTitle), prompts ? findsOneWidget : findsNothing);
        expect(find.text(_backgroundTitle), findsNothing);
      });
    });
  });

  group('background use status', () {
    const cases = {true: true, false: false, null: false};

    cases.forEach((restricted, prompts) {
      testWidgets('restricted=$restricted ${prompts ? 'prompts' : 'does not prompt'}', (
        tester,
      ) async {
        native.backgroundRestricted = restricted;

        await pumpPrompts(tester);

        expect(find.text(_backgroundTitle), prompts ? findsOneWidget : findsNothing);
        expect(find.text(_hibernationTitle), findsNothing);
      });
    });
  });

  testWidgets('a failed check shows nothing', (tester) async {
    native.statusError = PlatformException(code: 'boom');

    await pumpPrompts(tester);

    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('a missing channel shows nothing', (tester) async {
    native.statusError = MissingPluginException();

    await pumpPrompts(tester);

    expect(find.byType(FilledButton), findsNothing);
  });

  for (final platform in [
    TargetPlatform.iOS,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name} never asks the channel', (tester) async {
      native.hibernation = 'hibernation';
      native.backgroundRestricted = true;

      await pumpPrompts(tester);

      expect(native.calls, isEmpty);
      expect(find.byType(FilledButton), findsNothing);
    }, variant: TargetPlatformVariant.only(platform));
  }

  testWidgets('each prompt opens the page for its own restriction', (tester) async {
    native.hibernation = 'hibernation';
    native.backgroundRestricted = true;
    await pumpPrompts(tester);

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(native.calls.where((call) => call != 'getStatus'), [
      'openHibernationSettings',
      'openAppSettings',
    ]);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('says so if settings would not open', (tester) async {
    native.hibernation = 'hibernation';
    native.settingsOpen = false;
    await pumpPrompts(tester);

    await tester.tap(find.text('Open settings'));
    await tester.pumpAndSettle();

    expect(find.textContaining("Couldn't open settings"), findsOneWidget);
    expect(find.text(_hibernationTitle), findsOneWidget);
  });

  testWidgets('the prompt goes away on resume once the setting is off', (tester) async {
    native.hibernation = 'hibernation';
    await pumpPrompts(tester);
    expect(find.text(_hibernationTitle), findsOneWidget);

    await resume(tester);
    expect(find.text(_hibernationTitle), findsOneWidget, reason: 'setting not changed yet');

    native.hibernation = 'off';
    await resume(tester);
    expect(find.text(_hibernationTitle), findsNothing);
  });

  testWidgets('dismissing stays dismissed across resumes and restarts', (tester) async {
    native.hibernation = 'hibernation';
    await pumpPrompts(tester);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text(_hibernationTitle), findsNothing);

    await resume(tester);
    expect(find.text(_hibernationTitle), findsNothing);

    await pumpPrompts(tester);
    expect(find.text(_hibernationTitle), findsNothing);
  });

  testWidgets('shows one restriction at a time, the next after a dismissal', (tester) async {
    native.hibernation = 'hibernation';
    native.backgroundRestricted = true;
    await pumpPrompts(tester);

    expect(find.text(_hibernationTitle), findsOneWidget);
    expect(find.text(_backgroundTitle), findsNothing);

    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    expect(find.text(_hibernationTitle), findsNothing);
    expect(find.text(_backgroundTitle), findsOneWidget);
  });

  testWidgets('a dismissed restriction asks again if it is lifted and comes back', (tester) async {
    native.hibernation = 'hibernation';
    await pumpPrompts(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    native.hibernation = 'off';
    await resume(tester);
    expect(await RecordStore.instance.dismissedRestrictionPrompts(), isEmpty);

    native.hibernation = 'hibernation';
    await resume(tester);
    expect(find.text(_hibernationTitle), findsOneWidget);
  });

  testWidgets('a failed check does not forget a dismissal', (tester) async {
    native.hibernation = 'hibernation';
    await pumpPrompts(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    native.hibernation = 'unknown';
    await resume(tester);
    native.hibernation = 'hibernation';
    await resume(tester);

    expect(find.text(_hibernationTitle), findsNothing);
  });

  testWidgets('forgetting the relay forgets the dismissal, so setup asks again', (tester) async {
    native.hibernation = 'hibernation';
    await pumpPrompts(tester);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();

    await RecordStore.instance.clear();

    await pumpPrompts(tester);
    expect(find.text(_hibernationTitle), findsOneWidget);
  });

  testWidgets('the home screen shows the prompt', (tester) async {
    native.hibernation = 'hibernation';

    await tester.pumpWidget(const ProviderScope(child: MaterialApp(home: HomeScreen())));
    await tester.pumpAndSettle();

    expect(find.text(_hibernationTitle), findsOneWidget);
  });

  testWidgets('finishing setup lands on the prompt', (tester) async {
    native.hibernation = 'hibernation';
    DeliveryController.instance.setServiceForTesting(_NoDelivery());
    addTearDown(() => DeliveryController.instance.setServiceForTesting(null));

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ImportEnrollmentScreen())),
    );
    await tester.enterText(
      find.byType(TextField),
      jsonEncode({
        'v': 1,
        'record_id': '00000000-0000-4000-8000-000000000001',
        'private_key': _key,
        'public_key': _key,
        'inbox': 'token@pux.test',
        'server': 'https://pux.test',
      }),
    );
    // The progress bar animates during enrollment, so pumpAndSettle never settles.
    Future<void> settle() async {
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('Import and connect'));
    await settle();
    await tester.tap(find.text('Connect'));
    await settle();

    expect(find.text('Inbox address'), findsOneWidget);
    expect(find.text(_hibernationTitle), findsOneWidget);
  });
}
