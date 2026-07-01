import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/app.dart';

void main() {
  testWidgets('PuxApp renders loading state initially', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: PuxApp()),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
