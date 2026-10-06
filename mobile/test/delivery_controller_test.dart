import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/delivery_controller.dart';

void main() {
  test('backoff grows exponentially and is capped at five minutes', () {
    final random = Random(1);
    final delays = [for (var i = 0; i < 12; i++) DeliveryController.backoff(i, random: random)];

    expect(delays.first, greaterThanOrEqualTo(const Duration(seconds: 2)));
    expect(delays.first, lessThan(const Duration(seconds: 3)));
    expect(delays[3], greaterThanOrEqualTo(const Duration(seconds: 16)));
    for (final delay in delays) {
      expect(delay, lessThanOrEqualTo(const Duration(minutes: 5)));
    }
    expect(delays.last, const Duration(minutes: 5));
  });
}
