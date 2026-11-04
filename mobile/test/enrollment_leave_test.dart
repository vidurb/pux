import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pux/src/app.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/crypto_service.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/delivery_service.dart';
import 'package:pux/src/services/record_store.dart';

const _storageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
const _scannerChannel = MethodChannel('dev.steenbakker.mobile_scanner/scanner/method');

const _recordId = '00000000-0000-4000-8000-000000000001';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _server = 'https://pux.test';

final _enrollmentJson = jsonEncode({
  'v': 1,
  'record_id': _recordId,
  'private_key': _key,
  'public_key': _key,
  'inbox': 'token@pux.test',
  'server': _server,
});

class _FakeDelivery implements DeliveryService {
  int starts = 0;

  /// Whether the enrollment was already readable when delivery started.
  bool? enrolledAtStart;

  @override
  Future<void> init() async {
    starts++;
    enrolledAtStart = await RecordStore.instance.isEnrolled();
  }

  @override
  Future<void> stop() async {}
}

/// Secure storage behind its real method channel, so a write can be held
/// mid-enrollment or made to fail, which the in-memory test double can't do.
class _FakeStorage {
  final Map<String, String> values = {};
  Completer<void>? writeGate;
  Set<String> failWrites = {};
  bool failDeletes = false;

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return values[key];
      case 'write':
        await writeGate?.future;
        if (failWrites.contains(key)) {
          throw PlatformException(code: 'keystore', message: 'storage unavailable');
        }
        values[key!] = args['value'] as String;
      case 'delete':
        if (failDeletes) throw PlatformException(code: 'keystore', message: 'delete failed');
        values.remove(key);
      case 'deleteAll':
        values.clear();
    }
    return null;
  }
}

/// One way of enrolling, driven from the chooser up to the point where its
/// request is running.
class _EnrollmentRoute {
  const _EnrollmentRoute(this.name, this.platform, this.heldOn, this.open);

  final String name;
  final TargetPlatform platform;
  final _HeldOn heldOn;
  final Future<void> Function(WidgetTester tester) open;
}

enum _HeldOn { server, storage }

enum _Leave { systemBack, forcedPop }

Future<void> _settle(WidgetTester tester) async {
  // Progress bars animate during a request, so pumpAndSettle never settles.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tapAndSettle(WidgetTester tester, String label) async {
  await tester.tap(find.text(label));
  await _settle(tester);
}

Future<void> _scanQr(WidgetTester tester) async {
  tester.widget<MobileScanner>(find.byType(MobileScanner)).onDetect!(
    BarcodeCapture(barcodes: [Barcode(rawValue: _enrollmentJson)]),
  );
  await _settle(tester);
}

final _routes = [
  _EnrollmentRoute('create', TargetPlatform.android, _HeldOn.server, (tester) async {
    await _tapAndSettle(tester, 'Create new relay');
    await _tapAndSettle(tester, 'Generate keys and create relay');
  }),
  _EnrollmentRoute('QR scan', TargetPlatform.android, _HeldOn.storage, (tester) async {
    await _tapAndSettle(tester, 'Add to existing relay');
    await _scanQr(tester);
    await _tapAndSettle(tester, 'Connect');
  }),
  _EnrollmentRoute('import', TargetPlatform.linux, _HeldOn.storage, (tester) async {
    await _tapAndSettle(tester, 'Import enrollment');
    await tester.enterText(find.byType(TextField), _enrollmentJson);
    await _tapAndSettle(tester, 'Import and connect');
    await _tapAndSettle(tester, 'Connect');
  }),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeStorage storage;
  late _FakeDelivery delivery;
  late List<http.Request> requests;
  late List<String> scannerCalls;
  Completer<void>? requestGate;
  late http.Response createResponse;
  late http.Response deleteResponse;

  setUpAll(() => CryptoService.instance.init());

  setUp(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    storage = _FakeStorage();
    messenger.setMockMethodCallHandler(_storageChannel, storage.handle);
    scannerCalls = [];
    messenger.setMockMethodCallHandler(_scannerChannel, (call) async {
      scannerCalls.add(call.method);
      return switch (call.method) {
        'state' => 1,
        'start' => <String, Object?>{
          'textureId': 1,
          'cameraDirection': 1,
          'handlesCropAndRotation': true,
          'naturalDeviceOrientation': 'PORTRAIT_UP',
          'sensorOrientation': 90,
        },
        _ => null,
      };
    });

    requests = [];
    requestGate = null;
    createResponse = http.Response(
      jsonEncode({'record_id': _recordId, 'inbox_address': 'token@pux.test'}),
      201,
    );
    deleteResponse = http.Response('', 204);
    ApiClient.setInstanceForTesting(
      ApiClient.forTesting(
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'DELETE') return deleteResponse;
          await requestGate?.future;
          return createResponse;
        }),
      ),
    );

    RecordStore.instance.setServerUrlForTesting(_server);
    delivery = _FakeDelivery();
    DeliveryController.instance.setServiceForTesting(delivery);
    await DeliveryController.instance.stop();
  });

  tearDown(() async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_storageChannel, null);
    messenger.setMockMethodCallHandler(_scannerChannel, null);
    DeliveryController.instance.setServiceForTesting(null);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: PuxApp()));
    await _settle(tester);
  }

  /// Opens [route] with its request held, ready to be released.
  Future<void> startHeld(WidgetTester tester, _EnrollmentRoute route) async {
    await pumpApp(tester);
    switch (route.heldOn) {
      case _HeldOn.server:
        requestGate = Completer<void>();
      case _HeldOn.storage:
        storage.writeGate = Completer<void>();
    }
    await route.open(tester);
  }

  Future<void> release(WidgetTester tester, {required bool fail}) async {
    if (fail) {
      createResponse = http.Response('boom', 500);
      storage.failWrites = {'inbox', 'record_id'};
    }
    requestGate?.complete();
    storage.writeGate?.complete();
    requestGate = null;
    storage.writeGate = null;
    await _settle(tester);
  }

  Future<void> leave(WidgetTester tester, _Leave how) async {
    switch (how) {
      case _Leave.systemBack:
        await tester.binding.handlePopRoute();
      case _Leave.forcedPop:
        // Navigator.pop ignores PopScope, so this disposes the screen whatever
        // it does to stop the user leaving.
        tester.state<NavigatorState>(find.byType(Navigator).first).pop();
    }
    await _settle(tester);
  }

  void expectEnrolledAndDelivering(WidgetTester tester) {
    expect(find.text('Inbox address'), findsOneWidget, reason: 'home screen is showing');
    expect(find.text('Set up pux'), findsNothing);
    final container = ProviderScope.containerOf(tester.element(find.byType(MaterialApp)));
    expect(container.read(enrollmentProvider).value, isTrue, reason: 'app state updated');
    expect(storage.values['record_id'], _recordId);
    expect(delivery.starts, 1, reason: 'delivery started without a restart');
    expect(delivery.enrolledAtStart, isTrue);
    expect(DeliveryController.instance.status.value.state, DeliveryState.ready);
  }

  void expectNotEnrolled() {
    expect(storage.values, isEmpty, reason: 'nothing kept locally');
    expect(delivery.starts, 0);
  }

  for (final route in _routes) {
    final variant = TargetPlatformVariant.only(route.platform);

    group('${route.name}:', () {
      testWidgets('system back is refused mid-request, then the result arrives', (tester) async {
        await startHeld(tester, route);
        expect(find.byType(BackButton), findsNothing);

        await leave(tester, _Leave.systemBack);
        expect(find.text('Set up pux'), findsNothing, reason: 'still on the enrollment screen');

        await release(tester, fail: false);
        expectEnrolledAndDelivering(tester);
      }, variant: variant);

      testWidgets('system back mid-request, then failure: error shown, then free to leave', (
        tester,
      ) async {
        await startHeld(tester, route);

        await leave(tester, _Leave.systemBack);
        await release(tester, fail: true);

        expect(find.textContaining(RegExp('boom|storage unavailable')), findsOneWidget);
        expectNotEnrolled();

        expect(find.byType(BackButton), findsOneWidget);
        await leave(tester, _Leave.systemBack);
        expect(find.text('Set up pux'), findsOneWidget);
      }, variant: variant);

      testWidgets('screen disposed mid-request: success still reaches the app', (tester) async {
        await startHeld(tester, route);

        await leave(tester, _Leave.forcedPop);
        expect(find.text('Set up pux'), findsOneWidget);

        await release(tester, fail: false);
        expectEnrolledAndDelivering(tester);
      }, variant: variant);

      testWidgets('screen disposed mid-request: failure is still shown', (tester) async {
        await startHeld(tester, route);

        await leave(tester, _Leave.forcedPop);
        await release(tester, fail: true);

        expect(find.text('Set up pux'), findsOneWidget);
        expect(find.textContaining(RegExp('boom|storage unavailable')), findsOneWidget);
        expectNotEnrolled();
      }, variant: variant);
    });
  }

  testWidgets('create can be retried after a failure, without restarting the app', (tester) async {
    createResponse = http.Response('boom', 500);
    await pumpApp(tester);
    await _tapAndSettle(tester, 'Create new relay');
    await _tapAndSettle(tester, 'Generate keys and create relay');
    expect(find.textContaining('boom'), findsOneWidget);

    createResponse = http.Response(
      jsonEncode({'record_id': _recordId, 'inbox_address': 'token@pux.test'}),
      201,
    );
    await _tapAndSettle(tester, 'Generate keys and create relay');
    expectEnrolledAndDelivering(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('QR scan: the camera comes back after a failed save, so the user can retry', (
    tester,
  ) async {
    storage.failWrites = {'inbox'};
    await pumpApp(tester);
    await _tapAndSettle(tester, 'Add to existing relay');
    await _scanQr(tester);
    scannerCalls.clear();
    await _tapAndSettle(tester, 'Connect');
    expect(find.textContaining('storage unavailable'), findsOneWidget);
    expect(scannerCalls, contains('start'));

    storage.failWrites = {};
    await _scanQr(tester);
    await _tapAndSettle(tester, 'Connect');
    expectEnrolledAndDelivering(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  for (final route in _routes.where((route) => route.heldOn == _HeldOn.storage)) {
    testWidgets('${route.name}: back on the server prompt cancels, and nothing is saved', (
      tester,
    ) async {
      await pumpApp(tester);
      switch (route.name) {
        case 'QR scan':
          await _tapAndSettle(tester, 'Add to existing relay');
          await _scanQr(tester);
        default:
          await _tapAndSettle(tester, 'Import enrollment');
          await tester.enterText(find.byType(TextField), _enrollmentJson);
          await _tapAndSettle(tester, 'Import and connect');
      }
      expect(find.text('Connect to this server?'), findsOneWidget);

      await leave(tester, _Leave.systemBack);
      expect(find.text('Connect to this server?'), findsNothing);
      expect(find.text('Set up pux'), findsNothing, reason: 'still on the enrollment screen');
      expectNotEnrolled();

      await leave(tester, _Leave.systemBack);
      expect(find.text('Set up pux'), findsOneWidget);
    }, variant: TargetPlatformVariant.only(route.platform));
  }

  group('orphaned relays:', () {
    Future<void> createWithFailingSave(WidgetTester tester) async {
      storage.failWrites = {'inbox'};
      await pumpApp(tester);
      await _tapAndSettle(tester, 'Create new relay');
      await _tapAndSettle(tester, 'Generate keys and create relay');
    }

    testWidgets('a relay that could not be saved locally is deleted from the server', (
      tester,
    ) async {
      await createWithFailingSave(tester);

      final deleted = requests.where((request) => request.method == 'DELETE').single;
      expect(deleted.url.path, '/api/v1/records/$_recordId');
      expect(deleted.headers['authorization'], 'Bearer $_recordId');
      expect(find.textContaining('storage unavailable'), findsOneWidget);
      expectNotEnrolled();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('if that delete also fails, the user still sees the original error', (
      tester,
    ) async {
      deleteResponse = http.Response('nope', 500);
      await createWithFailingSave(tester);

      expect(find.textContaining('storage unavailable'), findsOneWidget);
      expect(find.textContaining('nope'), findsNothing);
      expectNotEnrolled();
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets('a failed create asks the server to delete nothing', (tester) async {
      createResponse = http.Response('boom', 500);
      await pumpApp(tester);
      await _tapAndSettle(tester, 'Create new relay');
      await _tapAndSettle(tester, 'Generate keys and create relay');

      expect(requests.where((request) => request.method == 'DELETE'), isEmpty);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));
  });

  testWidgets('enrolling again after forgetting a relay still reaches the home screen', (
    tester,
  ) async {
    // Here the chooser is a pushed route rather than PuxApp's home, so a
    // change to enrollmentProvider alone would leave it on screen.
    storage.values.addAll({
      'record_id': _recordId,
      'private_key': _key,
      'public_key': _key,
      'inbox': 'token@pux.test',
      'server_url': _server,
      'device_id': 'dev_1',
    });
    await pumpApp(tester);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await _settle(tester);
    await _tapAndSettle(tester, 'Remove this device');
    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await _settle(tester);
    expect(find.text('Set up pux'), findsOneWidget);
    expect(storage.values, isEmpty);

    requestGate = Completer<void>();
    await _tapAndSettle(tester, 'Create new relay');
    await _tapAndSettle(tester, 'Generate keys and create relay');
    await leave(tester, _Leave.forcedPop);
    await release(tester, fail: false);

    expectEnrolledAndDelivering(tester);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  group('RecordStore.saveEnrollment', () {
    final payload = {
      'record_id': _recordId,
      'private_key': _key,
      'public_key': _key,
      'inbox': 'token@pux.test',
      'server': 'https://relay.example',
    };

    test('a failed save leaves nothing behind', () async {
      storage.failWrites = {'record_id'};

      await expectLater(
        RecordStore.instance.saveEnrollment(payload),
        throwsA(isA<PlatformException>()),
      );

      expect(storage.values, isEmpty);
      expect(RecordStore.instance.serverUrl, _server);
    });

    test('never looks enrolled after a failed save, even if cleanup fails too', () async {
      for (final key in ['private_key', 'public_key', 'inbox', 'server_url', 'record_id']) {
        storage
          ..values.clear()
          ..failWrites = {key}
          ..failDeletes = true;

        await expectLater(
          RecordStore.instance.saveEnrollment(payload),
          throwsA(isA<PlatformException>()),
        );

        expect(await RecordStore.instance.isEnrolled(), isFalse, reason: 'failing on $key');
      }
    });
  });
}
