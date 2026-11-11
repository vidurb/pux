import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pux/src/app.dart';
import 'package:pux/src/screens/home_screen.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/delivery_service.dart';
import 'package:pux/src/services/record_store.dart';

const _recordId = '00000000-0000-4000-8000-000000000001';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

/// Delivery whose stop can be held, so the screen can go mid-forget.
class _HeldDelivery implements DeliveryService {
  Completer<void>? stopGate;

  @override
  Future<void> init() async {}

  @override
  Future<void> stop() async => stopGate?.future;
}

void main() {
  late List<http.Request> requests;

  setUp(() {
    requests = [];
    FlutterSecureStorage.setMockInitialValues({
      'record_id': _recordId,
      'private_key': _key,
      'public_key': _key,
      'inbox': 'token@pux.test',
      'server_url': 'https://pux.test',
      'device_id': 'dev_1',
    });
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
  });

  void respondWith(Future<http.Response> Function(http.Request) handler) {
    ApiClient.setInstanceForTesting(
      ApiClient.forTesting(
        client: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
      ),
    );
  }

  // The progress bar animates while removing, so pumpAndSettle never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openMenuItem(WidgetTester tester, String label) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: HomeScreen())),
    );
    await settle(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await settle(tester);
    await tester.tap(find.text(label));
    await settle(tester);
  }

  testWidgets(
    'Remove this device deletes the device on the server, then locally',
    (tester) async {
      respondWith((_) async => http.Response('', 204));

      await openMenuItem(tester, 'Remove this device');
      await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
      await settle(tester);

      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, '/api/v1/record/devices/dev_1');
      expect(find.text('Set up pux'), findsOneWidget);
      expect(await RecordStore.instance.recordId(), isNull);
    },
  );

  testWidgets('a failed removal offers to forget locally anyway', (
    tester,
  ) async {
    respondWith((_) async => throw http.ClientException('offline'));

    await openMenuItem(tester, 'Remove this device');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);

    expect(
      find.text("Couldn't remove this device from the server"),
      findsOneWidget,
    );
    await tester.tap(find.text('Forget locally anyway'));
    await settle(tester);

    expect(find.text('Set up pux'), findsOneWidget);
    expect(await RecordStore.instance.recordId(), isNull);
  });

  testWidgets('cancelling after a failed removal keeps the enrollment', (
    tester,
  ) async {
    respondWith((_) async => http.Response('', 500));

    await openMenuItem(tester, 'Remove this device');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await settle(tester);

    await tester.tap(find.text('Try again'));
    await settle(tester);
    expect(requests, hasLength(2));

    await tester.tap(find.text('Cancel'));
    await settle(tester);

    expect(find.text('Set up pux'), findsNothing);
    expect(await RecordStore.instance.recordId(), _recordId);
  });

  testWidgets(
    'Delete relay everywhere needs the word typed, then deletes the record',
    (tester) async {
      respondWith((_) async => http.Response('', 204));

      await openMenuItem(tester, 'Delete relay everywhere');
      final deleteButton = find.widgetWithText(
        FilledButton,
        'Delete everywhere',
      );
      expect(tester.widget<FilledButton>(deleteButton).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'delete');
      await tester.pump();
      await tester.tap(deleteButton);
      await settle(tester);

      expect(requests.single.method, 'DELETE');
      expect(requests.single.url.path, '/api/v1/record');
      expect(find.text('Set up pux'), findsOneWidget);
      expect(await RecordStore.instance.recordId(), isNull);
    },
  );

  testWidgets(
    'forgetting a relay still finishes if the screen goes meanwhile',
    (tester) async {
      final delivery = _HeldDelivery();
      DeliveryController.instance.setServiceForTesting(delivery);
      addTearDown(() => DeliveryController.instance.setServiceForTesting(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final navigatorKey = GlobalKey<NavigatorState>();

      expect(await container.read(enrollmentProvider.future), isTrue);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            navigatorKey: navigatorKey,
            home: const HomeScreen(),
          ),
        ),
      );
      await settle(tester);
      DeliveryController.instance.reportError(const RecordNotFoundException());
      await settle(tester);

      delivery.stopGate = Completer<void>();
      await tester.tap(find.text('Forget relay'));
      await settle(tester);
      unawaited(
        navigatorKey.currentState!.pushReplacement(
          MaterialPageRoute<void>(builder: (_) => const Text('Elsewhere')),
        ),
      );
      await settle(tester);
      expect(find.byType(HomeScreen), findsNothing);

      delivery.stopGate!.complete();
      await settle(tester);

      expect(await RecordStore.instance.recordId(), isNull);
      expect(await container.read(enrollmentProvider.future), isFalse);
      expect(find.text('Set up pux'), findsOneWidget);
    },
  );
}
