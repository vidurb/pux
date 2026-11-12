import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/fcm_registration.dart';
import 'package:pux/src/services/record_store.dart';

const _recordId = '00000000-0000-4000-8000-000000000001';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _fid = 'cK3xyBMtTnu-Wd_9Q2Zk1a';
const _newFid = 'fQ8_bLmZr2w-Xy7aAbCdEf';

/// FirebaseMessaging's registration API: [register] reports the current FID
/// on [onRegistered], which, like the plugin's, drops events nobody hears.
class _FakeMessaging implements FcmRegistrationSource {
  final _registered = StreamController<String>.broadcast(sync: true);
  String? fid = _fid;
  Object? registerError;
  int registerCalls = 0;

  @override
  Stream<String> get onRegistered => _registered.stream;

  @override
  Future<void> register() async {
    registerCalls++;
    if (registerError != null) throw registerError!;
    final current = fid;
    if (current != null) scheduleMicrotask(() => _registered.add(current));
  }

  /// The FID changed, or FCM synced on its own.
  void emit(String value) => _registered.add(value);
}

/// The server's side of POST /record/devices, enough to see device rows.
class _FakeServer {
  final requests = <Map<String, dynamic>>[];

  /// device_id → push_token
  final devices = <String, String>{};
  http.Response Function()? override;

  http.Response handle(http.Request request) {
    expect(request.url.path, '/api/v1/record/devices');
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    requests.add(body);
    final forced = override?.call();
    if (forced != null) return forced;

    final token = body['push_token'] as String;
    final replaces = body['device_id'] as String?;
    var id = devices.entries
        .where((e) => e.value == token)
        .map((e) => e.key)
        .firstOrNull;
    if (id == null && replaces != null && devices.containsKey(replaces)) {
      id = replaces;
    }
    id ??= 'dev_${devices.length + 1}';
    devices[id] = token;
    return http.Response(jsonEncode({'device_id': id, 'platform': 'fcm'}), 201);
  }
}

void main() {
  late _FakeMessaging messaging;
  late _FakeServer server;
  late List<Object> refreshErrors;
  late FcmRegistration registration;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
    await RecordStore.instance.saveEnrollment({
      'v': 1,
      'record_id': _recordId,
      'private_key': _key,
      'public_key': _key,
      'inbox': 'token@pux.test',
      'server': 'https://pux.test',
    });

    messaging = _FakeMessaging();
    server = _FakeServer();
    ApiClient.setInstanceForTesting(
      ApiClient.forTesting(
        client: MockClient((request) async => server.handle(request)),
      ),
    );
    refreshErrors = [];
    registration = FcmRegistration(
      source: messaging,
      onRefreshError: refreshErrors.add,
      timeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() => registration.stop());

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('registers the FID FCM reports, and stores the device ID', () async {
    await registration.start();

    expect(messaging.registerCalls, 1);
    expect(server.requests, [
      {'push_token': _fid, 'platform': 'fcm'},
    ]);
    expect(await RecordStore.instance.deviceId(), 'dev_1');
  });

  test(
    'a phone with an older registration replaces it, keeping one device',
    () async {
      // What a build that registered an FCM registration token left behind.
      server.devices['dev_old'] = '$_fid:APA91b-legacy-token';
      await RecordStore.instance.saveDeviceId('dev_old');

      await registration.start();

      expect(server.requests.single['device_id'], 'dev_old');
      expect(server.devices, {'dev_old': _fid});
      expect(await RecordStore.instance.deviceId(), 'dev_old');
    },
  );

  test('a new FID later replaces the old one in the same device', () async {
    await registration.start();

    messaging.emit(_newFid);
    await settle();

    expect(server.requests.last, {
      'push_token': _newFid,
      'platform': 'fcm',
      'device_id': 'dev_1',
    });
    expect(server.devices, {'dev_1': _newFid});
    expect(refreshErrors, isEmpty);
  });

  test('a routine sync repeating the registered FID sends nothing', () async {
    await registration.start();

    messaging.emit(_fid);
    await settle();

    expect(server.requests, hasLength(1));
  });

  test(
    'every start registers again, which keeps the server from aging it out',
    () async {
      await registration.start();
      await registration.start();

      expect(messaging.registerCalls, 2);
      expect(server.requests, hasLength(2));
      expect(server.requests.last['device_id'], 'dev_1');
      expect(server.devices, {'dev_1': _fid});
    },
  );

  test(
    'a change during a registration is sent after it, with its device ID',
    () async {
      final gate = Completer<void>();
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['push_token'] == _fid) await gate.future;
        return server.handle(request);
      });
      ApiClient.setInstanceForTesting(ApiClient.forTesting(client: client));

      final started = registration.start();
      await settle();
      messaging.emit(_newFid);
      await settle();
      expect(server.requests, isEmpty);

      gate.complete();
      await started;
      await settle();

      expect(server.requests.map((r) => r['push_token']), [_fid, _newFid]);
      expect(server.requests.last['device_id'], 'dev_1');
      expect(server.devices, {'dev_1': _newFid});
    },
  );

  test(
    'a failed refresh is reported, and the next change still registers',
    () async {
      await registration.start();

      server.override = () => http.Response('', 503);
      messaging.emit(_newFid);
      await settle();
      expect(refreshErrors, hasLength(1));

      server.override = null;
      messaging.emit('dB7_bLmZr2w-Xy7aAbCdEf');
      await settle();
      expect(server.devices, {'dev_1': 'dB7_bLmZr2w-Xy7aAbCdEf'});
    },
  );

  test(
    'the server refusing the first registration fails start for the caller',
    () async {
      server.override = () =>
          http.Response(jsonEncode({'error': 'too_many_devices'}), 422);

      await expectLater(
        registration.start(),
        throwsA(isA<TooManyDevicesException>()),
      );
      expect(refreshErrors, isEmpty);
    },
  );

  test(
    'FCM failing to register fails start without calling the server',
    () async {
      messaging.registerError = Exception('SERVICE_NOT_AVAILABLE');

      await expectLater(registration.start(), throwsException);
      expect(server.requests, isEmpty);
    },
  );

  test(
    'FCM never reporting an FID times out, and a late one still registers',
    () async {
      messaging.fid = null;

      await expectLater(registration.start(), throwsA(isA<TimeoutException>()));

      messaging.emit(_fid);
      await settle();
      expect(server.devices, {'dev_1': _fid});
    },
  );

  test('stopping ignores later FIDs', () async {
    await registration.start();
    await registration.stop();

    messaging.emit(_newFid);
    await settle();

    expect(server.requests, hasLength(1));
  });
}
