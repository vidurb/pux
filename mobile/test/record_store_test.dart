import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/record_store.dart';

void main() {
  final store = RecordStore.instance;

  const validKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

  Map<String, dynamic> validPayload() => {
        'v': 1,
        'record_id': '00000000-0000-4000-8000-000000000001',
        'private_key': validKey,
        'public_key': validKey,
        'inbox': 'token@pux.example',
        'server': 'https://pux.example',
      };

  test('parseQr validates required keys', () {
    expect(
      () => store.parseQr('{"v":1}'),
      throwsFormatException,
    );
  });

  test('parseQr rejects unsupported version', () {
    expect(
      () => store.parseQr(jsonEncode({...validPayload(), 'v': 2})),
      throwsFormatException,
    );
  });

  test('parseQr accepts valid payload', () {
    final payload = store.parseQr(jsonEncode(validPayload()));
    expect(payload['record_id'], isNotEmpty);
    expect(payload['public_key'], validKey);
  });

  test('parseQr requires public_key', () {
    final payload = validPayload()..remove('public_key');
    expect(
      () => store.parseQr(jsonEncode(payload)),
      throwsFormatException,
    );
  });

  test('saveEnrollment rejects invalid key length', () async {
    final payload = validPayload();
    payload['private_key'] = 'too-short';

    expect(
      () => store.saveEnrollment(payload),
      throwsFormatException,
    );
  });
}
