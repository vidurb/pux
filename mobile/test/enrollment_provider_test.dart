import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/app.dart';

const _storageChannel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

void main() {
  testWidgets('a failed enrollment read shows the error straight away', (tester) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_storageChannel, (call) async {
      throw PlatformException(code: 'keystore', message: 'keystore unavailable');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(_storageChannel, null));

    await tester.pumpWidget(const ProviderScope(child: PuxApp()));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('keystore unavailable'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
