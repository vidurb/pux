import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/record_store.dart';

void main() {
  test('parseQr validates required keys', () {
    final store = RecordStore.instance;
    expect(
      () => store.parseQr('{"v":1}'),
      throwsFormatException,
    );
  });
}
