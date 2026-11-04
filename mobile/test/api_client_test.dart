import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pux/src/services/api_client.dart';
import 'package:pux/src/services/record_store.dart';

void main() {
  setUp(() {
    RecordStore.instance.setServerUrlForTesting('https://pux.test');
  });

  test('createRecord returns record_id and inbox_address', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.path, '/api/v1/records');
      expect(request.method, 'POST');
      final body = jsonDecode(request.body);
      expect(body['public_key'], 'test_pub_key');

      return http.Response(jsonEncode({'record_id': 'rec_123', 'inbox_address': 'inbox_456'}), 200);
    });

    final client = ApiClient.forTesting(client: mockClient);
    ApiClient.setInstanceForTesting(client);

    final result = await client.createRecord(publicKey: 'test_pub_key');
    expect(result['record_id'], 'rec_123');
    expect(result['inbox_address'], 'inbox_456');
  });

  test('registerDevice makes correct request', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.path, '/api/v1/record/devices');
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer rec_123');
      final body = jsonDecode(request.body);
      expect(body['push_token'], 'token_123');
      expect(body['platform'], 'ios');

      return http.Response('{}', 200);
    });

    final client = ApiClient.forTesting(client: mockClient);
    ApiClient.setInstanceForTesting(client);

    await client.registerDevice(recordId: 'rec_123', pushToken: 'token_123', platform: 'ios');
  });

  test('listPendingDeliveries returns parsed deliveries', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.path, '/api/v1/record/deliveries');
      expect(request.method, 'GET');
      expect(request.headers['authorization'], 'Bearer rec_123');

      return http.Response(
        jsonEncode({
          'deliveries': [
            {
              'delivery_id': 'del_1',
              'envelope': {'foo': 'bar'},
            },
          ],
        }),
        200,
      );
    });

    final client = ApiClient.forTesting(client: mockClient);
    ApiClient.setInstanceForTesting(client);

    final deliveries = await client.listPendingDeliveries(recordId: 'rec_123');
    expect(deliveries.length, 1);
    expect(deliveries[0].deliveryId, 'del_1');
    expect(deliveries[0].envelope['foo'], 'bar');
  });

  test('ackDelivery makes correct request', () async {
    final mockClient = MockClient((request) async {
      expect(request.url.path, '/api/v1/record/deliveries/del_1');
      expect(request.method, 'DELETE');
      expect(request.headers['authorization'], 'Bearer rec_123');

      return http.Response('', 204);
    });

    final client = ApiClient.forTesting(client: mockClient);
    ApiClient.setInstanceForTesting(client);

    await client.ackDelivery(recordId: 'rec_123', deliveryId: 'del_1');
  });

  test('registerDevice maps 404 to RecordNotFoundException', () async {
    final client = ApiClient.forTesting(
      client: MockClient((_) async => http.Response('{"error":"not_found"}', 404)),
    );

    expect(
      () => client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
      throwsA(isA<RecordNotFoundException>()),
    );
  });

  test(
    'an unknown relay (401 or 404) is RecordNotFoundException when registering or polling',
    () async {
      for (final response in [
        http.Response('{"error":"unauthorized"}', 401),
        http.Response('{"error":"not_found"}', 404),
      ]) {
        final client = ApiClient.forTesting(client: MockClient((_) async => response));

        await expectLater(
          client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
          throwsA(isA<RecordNotFoundException>()),
        );
        await expectLater(
          client.listPendingDeliveries(recordId: 'rec_123'),
          throwsA(isA<RecordNotFoundException>()),
        );
      }
    },
  );

  test('deletes and acks treat an unknown relay (401 or 404) as already gone', () async {
    for (final response in [
      http.Response('{"error":"unauthorized"}', 401),
      http.Response('{"error":"not_found"}', 404),
    ]) {
      final client = ApiClient.forTesting(client: MockClient((_) async => response));

      await client.deleteDevice(recordId: 'rec_123', deviceId: 'dev_1');
      await client.deleteRecord(recordId: 'rec_123');
      await client.ackDelivery(recordId: 'rec_123', deliveryId: 'del_1');
    }
  });

  test('the record ID is only ever sent in the authorization header', () async {
    const recordId = '3f0c9a52-7a44-4d1e-9b1a-1c2d3e4f5a6b';
    final requests = <http.Request>[];
    final client = ApiClient.forTesting(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{"deliveries":[]}', 200);
      }),
    );

    await client.registerDevice(recordId: recordId, pushToken: 't', platform: 'fcm');
    await client.deleteDevice(recordId: recordId, deviceId: 'dev_1');
    await client.deleteRecord(recordId: recordId);
    await client.listPendingDeliveries(recordId: recordId);
    await client.ackDelivery(recordId: recordId, deliveryId: 'del_1');

    expect(requests, hasLength(5));
    for (final request in requests) {
      expect(request.url.toString(), isNot(contains(recordId)));
      expect(request.body, isNot(contains(recordId)));
      expect(request.headers['authorization'], 'Bearer $recordId');
    }
  });

  test('registerDevice surfaces other failures as retryable errors', () async {
    final client = ApiClient.forTesting(client: MockClient((_) async => http.Response('', 503)));

    expect(
      () => client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
      throwsA(isNot(isA<RecordNotFoundException>())),
    );
  });

  test('registerDevice returns the device_id', () async {
    final client = ApiClient.forTesting(
      client: MockClient(
        (_) async => http.Response(jsonEncode({'device_id': 'dev_1', 'platform': 'fcm'}), 201),
      ),
    );

    expect(
      await client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
      'dev_1',
    );
  });

  test('registerDevice maps 422 too_many_devices to TooManyDevicesException', () async {
    final client = ApiClient.forTesting(
      client: MockClient((_) async => http.Response('{"error":"too_many_devices"}', 422)),
    );

    expect(
      () => client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
      throwsA(isA<TooManyDevicesException>()),
    );
  });

  test('429 responses surface as RateLimitedException', () async {
    final client = ApiClient.forTesting(
      client: MockClient((_) async => http.Response('{"error":"rate_limit_exceeded"}', 429)),
    );

    expect(
      () => client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
      throwsA(isA<RateLimitedException>()),
    );
    expect(
      () => client.listPendingDeliveries(recordId: 'rec_123'),
      throwsA(isA<RateLimitedException>()),
    );
    expect(() => client.deleteRecord(recordId: 'rec_123'), throwsA(isA<RateLimitedException>()));
  });

  test('deleteDevice sends DELETE for the device', () async {
    final client = ApiClient.forTesting(
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/record/devices/dev_1');
        expect(request.headers['authorization'], 'Bearer rec_123');
        return http.Response('', 204);
      }),
    );

    await client.deleteDevice(recordId: 'rec_123', deviceId: 'dev_1');
  });

  test('deleteRecord sends DELETE for the record', () async {
    final client = ApiClient.forTesting(
      client: MockClient((request) async {
        expect(request.method, 'DELETE');
        expect(request.url.path, '/api/v1/record');
        expect(request.headers['authorization'], 'Bearer rec_123');
        return http.Response('', 204);
      }),
    );

    await client.deleteRecord(recordId: 'rec_123');
  });

  test('deletes treat 404 as already gone', () async {
    final client = ApiClient.forTesting(
      client: MockClient((_) async => http.Response('{"error":"not_found"}', 404)),
    );

    await client.deleteDevice(recordId: 'rec_123', deviceId: 'dev_1');
    await client.deleteRecord(recordId: 'rec_123');
  });

  test('deletes surface server errors', () async {
    final client = ApiClient.forTesting(client: MockClient((_) async => http.Response('', 500)));

    expect(
      () => client.deleteDevice(recordId: 'rec_123', deviceId: 'dev_1'),
      throwsA(isA<Exception>()),
    );
    expect(() => client.deleteRecord(recordId: 'rec_123'), throwsA(isA<Exception>()));
  });

  test('deliveryWebSocketUrl targets /ws/delivery over wss without the record ID', () {
    final url = Uri.parse(ApiClient.forTesting().deliveryWebSocketUrl());
    expect(url.scheme, 'wss');
    expect(url.host, 'pux.test');
    expect(url.path, '/ws/delivery');
    expect(url.hasQuery, isFalse);
  });

  test('deliveryWebSocketUrl uses ws for http servers and keeps the port', () {
    RecordStore.instance.setServerUrlForTesting('http://localhost:4000');
    final url = Uri.parse(ApiClient.forTesting().deliveryWebSocketUrl());
    expect(url.toString(), 'ws://localhost:4000/ws/delivery');
  });
}
