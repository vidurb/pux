import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/screens/import_enrollment_screen.dart';
import 'package:pux/src/services/record_store.dart';

const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    RecordStore.instance.setServerUrlForTesting('https://pux.default');
  });

  // The progress bar animates while the dialog is open, so pumpAndSettle never settles.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> submit(WidgetTester tester, Map<String, dynamic> payload) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ImportEnrollmentScreen())),
    );
    await tester.enterText(find.byType(TextField), jsonEncode(payload));
    await tester.tap(find.text('Import and connect'));
    await settle(tester);
  }

  Map<String, dynamic> payload({String server = 'https://relay.example:8443'}) => {
    'v': 1,
    'record_id': '00000000-0000-4000-8000-000000000001',
    'private_key': _key,
    'public_key': _key,
    'inbox': 'token@relay.example',
    'server': server,
  };

  testWidgets('shows the server host and saves nothing when cancelled', (tester) async {
    await submit(tester, payload());

    expect(find.text('Connect to this server?'), findsOneWidget);
    expect(find.text('relay.example:8443'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(await RecordStore.instance.recordId(), isNull);
  });

  testWidgets('rejects an insecure server before asking', (tester) async {
    await submit(tester, payload(server: 'http://relay.example'));

    expect(find.text('Connect to this server?'), findsNothing);
    expect(find.textContaining('https is required'), findsOneWidget);
    expect(await RecordStore.instance.recordId(), isNull);
  });
}
