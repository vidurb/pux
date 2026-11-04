import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    store.setServerUrlForTesting('https://pux.default');
  });

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

  test('parseQr rejects a record_id that is not a UUID', () {
    expect(
      () => store.parseQr(jsonEncode({...validPayload(), 'record_id': '../../admin'})),
      throwsFormatException,
    );
  });

  test('parseQr rejects plain http servers', () {
    expect(
      () => store.parseQr(jsonEncode({...validPayload(), 'server': 'http://evil.example'})),
      throwsFormatException,
    );
  });

  test('validateServerUrl accepts https and local http only', () {
    expect(RecordStore.validateServerUrl('https://pux.example'), 'https://pux.example');
    expect(RecordStore.validateServerUrl('https://pux.example:8443/'), 'https://pux.example:8443');
    expect(RecordStore.validateServerUrl('http://localhost:4000'), 'http://localhost:4000');
    expect(RecordStore.validateServerUrl('http://127.0.0.1:4000'), 'http://127.0.0.1:4000');
    expect(RecordStore.validateServerUrl('http://10.0.2.2:4000'), 'http://10.0.2.2:4000');

    for (final bad in [
      'http://pux.example',
      'http://192.168.1.10:4000',
      'ftp://pux.example',
      'javascript:alert(1)',
      'pux.example',
      'https://user:pass@pux.example',
      'https://pux.example/api',
      'https://pux.example?x=1',
    ]) {
      expect(() => RecordStore.validateServerUrl(bad), throwsFormatException, reason: bad);
    }
  });

  test('enrollmentServer falls back to the current server and trusts the build default', () {
    expect(store.enrollmentServer(validPayload()..remove('server')), 'https://pux.default');

    store.setServerUrlForTesting('http://192.168.1.10:4000');
    expect(
      store.enrollmentServer({...validPayload(), 'server': 'http://192.168.1.10:4000'}),
      'http://192.168.1.10:4000',
    );
  });

  test('saveEnrollment stores the normalised server', () async {
    await store.saveEnrollment({...validPayload(), 'server': 'https://pux.example/'});
    expect(store.serverUrl, 'https://pux.example');
    expect((await store.enrollmentPayload())['server'], 'https://pux.example');
  });

  test('saveEnrollment rejects an insecure server', () async {
    expect(
      () => store.saveEnrollment({...validPayload(), 'server': 'http://evil.example'}),
      throwsFormatException,
    );
  });

  test('device ID is stored and cleared with the enrollment', () async {
    await store.saveEnrollment(validPayload());
    await store.saveDeviceId('dev_1');
    expect(await store.deviceId(), 'dev_1');

    await store.saveDeviceId(null);
    expect(await store.deviceId(), 'dev_1');

    await store.clear();
    expect(await store.deviceId(), isNull);
    expect(store.serverUrl, 'https://pux.default');
  });
}
