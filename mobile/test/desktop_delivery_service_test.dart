import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/delivery_controller.dart';
import 'package:pux/src/services/desktop_delivery_service.dart';
import 'package:pux/src/services/record_store.dart';

const _recordId = '00000000-0000-4000-8000-000000000001';
const _key = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  final service = DesktopDeliveryService.instance;

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
  });

  tearDown(() => service.stop());

  Future<void> waitFor(bool Function() condition) async {
    for (var i = 0; i < 200 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(condition(), isTrue);
  }

  void stubServer(http.Response Function(http.Request) handler) {
    ApiClient.setInstanceForTesting(
      ApiClient.forTesting(client: MockClient((request) async => handler(request))),
    );
  }

  http.Response registered() => http.Response(jsonEncode({'device_id': 'dev_1'}), 201);

  test('an app left running keeps re-registering as the same device', () async {
    final registrations = <Map<String, dynamic>>[];
    stubServer((request) {
      expect(request.url.path, '/api/v1/records/$_recordId/devices');
      registrations.add(jsonDecode(request.body) as Map<String, dynamic>);
      return registered();
    });

    service.keepRegistered(interval: const Duration(milliseconds: 1));
    await waitFor(() => registrations.length >= 2);

    expect(registrations.map((body) => body['platform']), everyElement('desktop'));
    expect(registrations.map((body) => body['push_token']).toSet(), hasLength(1));
  });

  test('stopping ends the re-registration', () async {
    var count = 0;
    stubServer((_) {
      count++;
      return registered();
    });

    service.keepRegistered(interval: const Duration(milliseconds: 1));
    await waitFor(() => count >= 1);
    await service.stop();

    final atStop = count;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(count, atStop);
  });

  test('a transient failure leaves the timer running', () async {
    var count = 0;
    stubServer((_) {
      count++;
      return count == 1 ? http.Response('', 503) : registered();
    });

    service.keepRegistered(interval: const Duration(milliseconds: 1));
    await waitFor(() => count >= 2);
  });

  test('a relay the server no longer knows is reported', () async {
    stubServer((_) => http.Response('', 404));

    service.keepRegistered(interval: const Duration(milliseconds: 1));
    await waitFor(
      () => DeliveryController.instance.status.value.state == DeliveryState.recordUnknown,
    );
  });
}
