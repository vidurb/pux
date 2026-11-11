import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/held_codes.dart';
import 'package:pux/src/services/desktop_delivery_service.dart';
import 'package:pux/src/services/notification_service.dart';
import 'package:pux/src/services/sensitive_clipboard.dart';

HeldDelivery _held(String id, RelayNotification notification) => HeldDelivery(
  deliveryId: id,
  notification: notification,
  expiresAt: DateTime.now().add(const Duration(minutes: 15)),
  notified: false,
);

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;

  Future<void> pump(
    WidgetTester tester,
    ValueListenable<List<HeldDelivery>> held,
  ) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: HeldCodes(held: held)),
    ),
  );

  testWidgets('shows nothing when no code is held', (tester) async {
    await pump(tester, ValueNotifier(const []));

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('shows a held code and removes it once it is no longer held', (
    tester,
  ) async {
    final held = ValueNotifier([
      _held(
        'a',
        const RelayNotification(
          title: 'OTP from HDFC',
          body: '123456',
          code: '123456',
        ),
      ),
    ]);
    await pump(tester, held);

    expect(find.text('OTP from HDFC'), findsOneWidget);
    expect(find.text('123456'), findsOneWidget);

    held.value = const [];
    await tester.pump();

    expect(find.text('123456'), findsNothing);
  });

  testWidgets('copies through the sensitive clipboard', (tester) async {
    final copied = <String>[];
    messenger.setMockMethodCallHandler(SensitiveClipboard.channel, (
      call,
    ) async {
      copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(SensitiveClipboard.channel, null),
    );
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    await pump(
      tester,
      ValueNotifier([
        _held(
          'a',
          const RelayNotification(title: 'OTP', body: '123456', code: '123456'),
        ),
      ]),
    );
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();

    expect(copied, ['123456']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('offers no copy when there is no code', (tester) async {
    await pump(
      tester,
      ValueNotifier([
        _held(
          'a',
          const RelayNotification(
            title: 'Forwarding',
            body: 'https://example.test',
          ),
        ),
      ]),
    );

    expect(find.text('https://example.test'), findsOneWidget);
    expect(find.byTooltip('Copy code'), findsNothing);
  });

  group('recent codes', () {
    Future<void> pumpRecent(
      WidgetTester tester,
      ValueListenable<List<HeldDelivery>> recent,
    ) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: RecentCodes(recent: recent)),
      ),
    );

    testWidgets('shows nothing when there are none', (tester) async {
      await pumpRecent(tester, ValueNotifier(const []));

      expect(find.byType(Text), findsNothing);
    });

    testWidgets('lists a recent code with its own heading, until it goes', (
      tester,
    ) async {
      final recent = ValueNotifier([
        _held(
          'a',
          const RelayNotification(
            title: 'OTP from HDFC',
            body: '654321',
            code: '654321',
          ),
        ),
      ]);
      await pumpRecent(tester, recent);

      expect(find.text('Recent codes'), findsOneWidget);
      expect(find.text('Codes that may not have appeared'), findsNothing);
      expect(find.text('654321'), findsOneWidget);
      expect(find.byTooltip('Copy code'), findsOneWidget);

      recent.value = const [];
      await tester.pump();

      expect(find.text('654321'), findsNothing);
    });
  });
}
