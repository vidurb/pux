import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/enroll_chooser_screen.dart';

void main() {
  testWidgets('setup screen does not claim the private key never leaves', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: EnrollChooserScreen())),
    );

    expect(find.textContaining('never leaves'), findsNothing);
    expect(
      find.textContaining('only if you add another device'),
      findsOneWidget,
    );
  });
}
