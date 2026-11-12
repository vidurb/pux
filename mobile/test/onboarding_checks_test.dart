import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pux/src/screens/home_screen.dart';
import 'package:pux/src/screens/server_status.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/delivery_service.dart';
import 'package:pux/src/services/record_store.dart';

const _recordId = '00000000-0000-4000-8000-000000000001';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

class _CountingDelivery implements DeliveryService {
  int starts = 0;

  @override
  Future<void> init() async => starts++;

  @override
  Future<void> stop() async {}
}

/// The home screen's server status row and "Send a test code" button.
void main() {
  late List<http.Request> requests;
  late Future<http.Response> Function(http.Request) handler;

  setUp(() {
    requests = [];
    handler = (_) async => http.Response('{"status":"ok"}', 200);
    FlutterSecureStorage.setMockInitialValues({
      'record_id': _recordId,
      'private_key': _key,
      'public_key': _key,
      'inbox': 'token@pux.test',
      'server_url': 'https://pux.test:8443',
      'device_id': 'dev_1',
    });
    RecordStore.instance.setServerUrlForTesting('https://pux.test:8443');
    ApiClient.setInstanceForTesting(
      ApiClient.forTesting(
        client: MockClient((request) {
          requests.add(request);
          return handler(request);
        }),
      ),
    );
  });

  List<http.Request> healthChecks() =>
      requests.where((r) => r.url.path == '/health').toList();

  // Spinners animate, so pumpAndSettle never settles while one shows.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> showHome(WidgetTester tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: HomeScreen())),
    );
    await settle(tester);
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
    await settle(tester);
  }

  group('server status', () {
    test('names the host, with a port only when there is one', () {
      expect(ServerStatus.hostOf('https://pux.vidur.xyz'), 'pux.vidur.xyz');
      expect(ServerStatus.hostOf('http://10.0.2.2:4000'), '10.0.2.2:4000');
    });

    testWidgets('shows the server and that it is reachable', (tester) async {
      final health = Completer<http.Response>();
      handler = (_) => health.future;

      await showHome(tester);
      expect(find.text('Server: pux.test:8443'), findsOneWidget);
      expect(find.text('Checking…'), findsOneWidget);

      health.complete(http.Response('{"status":"ok"}', 200));
      await settle(tester);

      expect(find.text('Reachable'), findsOneWidget);
      expect(
        healthChecks().single.url.toString(),
        'https://pux.test:8443/health',
      );
    });

    testWidgets('shows why it is unreachable, and checks again on a tap', (
      tester,
    ) async {
      handler = (_) async => throw http.ClientException('Connection refused');
      await showHome(tester);
      expect(
        find.text("Can't reach the server: Connection refused"),
        findsOneWidget,
      );

      handler = (_) async => http.Response('{"status":"ok"}', 200);
      await tester.tap(find.byTooltip('Check again'));
      await settle(tester);

      expect(find.text('Reachable'), findsOneWidget);
      expect(healthChecks(), hasLength(2));
    });

    testWidgets('shows a server error, and checks again on resume', (
      tester,
    ) async {
      handler = (_) async => http.Response('{"status":"error"}', 503);
      await showHome(tester);
      expect(
        find.text('Server error: its database is unavailable'),
        findsOneWidget,
      );

      handler = (_) async => http.Response('{"status":"ok"}', 200);
      await resume(tester);

      expect(find.text('Reachable'), findsOneWidget);
      expect(healthChecks(), hasLength(2));
    });

    testWidgets(
      'checks again when delivery starts retrying, and a tap that finds the '
      'server retries delivery at once',
      (tester) async {
        final delivery = _CountingDelivery();
        DeliveryController.instance.setServiceForTesting(delivery);
        addTearDown(() async {
          await DeliveryController.instance.stop();
          DeliveryController.instance.setServiceForTesting(null);
        });

        handler = (_) async => throw http.ClientException('offline');
        await showHome(tester);
        expect(healthChecks(), hasLength(1));

        DeliveryController.instance.reportError(Exception('offline'));
        await settle(tester);
        expect(healthChecks(), hasLength(2));
        expect(delivery.starts, 0);

        handler = (_) async => http.Response('{"status":"ok"}', 200);
        await tester.tap(find.byTooltip('Check again'));
        await settle(tester);

        expect(find.text('Reachable'), findsOneWidget);
        expect(delivery.starts, 1);
        expect(
          DeliveryController.instance.status.value.state,
          DeliveryState.ready,
        );
      },
    );
  });

  group('send a test code', () {
    List<http.Request> testCodeRequests() =>
        requests.where((r) => r.url.path == '/api/v1/record/test').toList();

    void answerTestCode(int status, String body) {
      handler = (request) async => request.url.path == '/health'
          ? http.Response('{"status":"ok"}', 200)
          : http.Response(body, status);
    }

    Future<void> tapSend(WidgetTester tester) async {
      await showHome(tester);
      final button = find.text('Send a test code');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(button);
      await settle(tester);
    }

    testWidgets('says which code to look for, and how to check mail too', (
      tester,
    ) async {
      answerTestCode(202, '{"otp":"482913","devices":2}');

      await tapSend(tester);

      final sent = testCodeRequests().single;
      expect(sent.method, 'POST');
      expect(sent.headers['authorization'], 'Bearer $_recordId');
      expect(sent.url.toString(), isNot(contains(_recordId)));

      expect(find.text('Test code sent'), findsOneWidget);
      expect(find.text('482913'), findsOneWidget);
      expect(find.textContaining('arrives as a notification'), findsOneWidget);
      expect(
        find.textContaining('It went to all 2 devices on this relay.'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'email "Your OTP is 123456" straight to token@pux.test',
        ),
        findsOneWidget,
      );

      await tester.tap(find.text('Done'));
      await settle(tester);
      expect(find.text('Test code sent'), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.android));

    testWidgets(
      'on a desktop, says the code may also be listed on the home screen',
      (tester) async {
        answerTestCode(202, '{"otp":"482913","devices":1}');

        await tapSend(tester);

        expect(
          find.textContaining('also listed on this screen'),
          findsOneWidget,
        );
        expect(find.textContaining('It went to all'), findsNothing);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );

    testWidgets('says to wait when rate limited', (tester) async {
      answerTestCode(429, '{"error":"rate_limit_exceeded"}');

      await tapSend(tester);

      expect(find.text('Test code sent'), findsNothing);
      expect(find.textContaining('Too many test codes'), findsOneWidget);
    });

    testWidgets('explains a relay with no devices', (tester) async {
      answerTestCode(409, '{"error":"no_devices"}');

      await tapSend(tester);

      expect(
        find.textContaining('No device is registered on this relay yet'),
        findsOneWidget,
      );
    });

    testWidgets('shows other failures', (tester) async {
      handler = (request) async => request.url.path == '/health'
          ? http.Response('{"status":"ok"}', 200)
          : throw http.ClientException('offline');

      await tapSend(tester);

      expect(find.textContaining("Couldn't send a test code"), findsOneWidget);
      // The button works again.
      final button = tester.widget<OutlinedButton>(
        find.ancestor(
          of: find.text('Send a test code'),
          matching: find.byWidgetPredicate((w) => w is OutlinedButton),
        ),
      );
      expect(button.onPressed, isNotNull);
    });
  });
}
