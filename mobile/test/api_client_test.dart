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
      expect(request.url.path, '/api/v1/records/rec_123/devices');
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
      expect(request.url.path, '/api/v1/records/rec_123/deliveries');
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
      expect(request.url.path, '/api/v1/records/rec_123/deliveries/del_1');
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

  test('registerDevice surfaces other failures as retryable errors', () async {
    final client = ApiClient.forTesting(client: MockClient((_) async => http.Response('', 503)));

    expect(
      () => client.registerDevice(recordId: 'rec_123', pushToken: 't', platform: 'fcm'),
      throwsA(isNot(isA<RecordNotFoundException>())),
    );
  });

  test('deliveryWebSocketUrl targets /ws/delivery over wss', () {
    final url = Uri.parse(ApiClient.forTesting().deliveryWebSocketUrl('rec_123'));
    expect(url.scheme, 'wss');
    expect(url.host, 'pux.test');
    expect(url.path, '/ws/delivery');
    expect(url.queryParameters['token'], 'rec_123');
  });
}
