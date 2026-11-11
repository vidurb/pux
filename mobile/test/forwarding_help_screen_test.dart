import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/forwarding_help_screen.dart';

void main() {
  testWidgets('shows the inbox address and every known sender', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: ForwardingHelpScreen(inbox: 'token@pux.test')),
    );

    expect(find.text('token@pux.test'), findsOneWidget);
    expect(find.textContaining('enter token@pux.test'), findsWidgets);

    for (final sender in knownOtpSenders) {
      await tester.scrollUntilVisible(
        find.text('Subject: ${sender.subject}'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('From: ${sender.from}'), findsOneWidget);
    }
  });

  testWidgets('falls back to a placeholder without an inbox address', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: ForwardingHelpScreen()));

    expect(find.byTooltip('Copy inbox address'), findsNothing);
    expect(find.textContaining('enter your inbox address'), findsWidgets);
  });
}
