import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/notification_service.dart';

void main() {
  testWidgets('expire like held codes, after 15 minutes', (tester) async {
    final codes = NotificationCodes();
    codes.put(1, '123456');

    await tester.pump(const Duration(minutes: 14, seconds: 59));
    expect(codes.length, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(codes.length, 0);
    expect(codes.take(1), isNull);
  });

  testWidgets('taking a code cancels its expiry', (tester) async {
    final codes = NotificationCodes(lifetime: const Duration(minutes: 1));
    codes.put(1, '123456');

    expect(codes.take(1), '123456');
    expect(codes.take(1), isNull);
    // testWidgets fails if a timer is still pending here.
  });

  testWidgets('showing a code again restarts its expiry', (tester) async {
    final codes = NotificationCodes(lifetime: const Duration(minutes: 1));
    codes.put(1, '111111');
    await tester.pump(const Duration(seconds: 45));
    codes.put(1, '222222');

    await tester.pump(const Duration(seconds: 45));
    expect(codes.take(1), '222222');
  });
}
