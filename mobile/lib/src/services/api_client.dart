import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'record_store.dart';

class PendingDelivery {
  const PendingDelivery({
    required this.deliveryId,
    required this.envelope,
  });

  final String deliveryId;
  final Map<String, dynamic> envelope;
}

class ApiClient {
  ApiClient._({http.Client? client}) : _client = client ?? http.Client();

  @visibleForTesting
  ApiClient.forTesting({http.Client? client}) : _client = client ?? http.Client();

  static ApiClient _instance = ApiClient._();
  static ApiClient get instance => _instance;

  @visibleForTesting
  static void setInstanceForTesting(ApiClient client) {
    _instance = client;
  }

  final http.Client _client;

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, String>> createRecord({required String publicKey}) async {
    final uri = Uri.parse('${RecordStore.instance.serverUrl}/api/v1/records');
    final response = await _client
        .post(
          uri,
          headers: {'content-type': 'application/json'},
          body: jsonEncode({'public_key': publicKey}),
        )
        .timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body.isEmpty ? '(empty body)' : response.body;
      throw Exception('Record creation failed (${response.statusCode}): $body');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final recordId = decoded['record_id'] as String?;
    final inboxAddress = decoded['inbox_address'] as String?;
    if (recordId == null || inboxAddress == null) {
      throw Exception('Record creation returned an incomplete response');
    }

    return {
      'record_id': recordId,
      'inbox_address': inboxAddress,
    };
  }

  Future<void> registerDevice({
    required String recordId,
    required String pushToken,
    required String platform,
  }) async {
    final uri = Uri.parse('${RecordStore.instance.serverUrl}/api/v1/records/$recordId/devices');
    final response = await _client
        .post(
          uri,
          headers: {
            'authorization': 'Bearer $recordId',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'push_token': pushToken,
            'platform': platform,
          }),
        )
        .timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body.isEmpty ? '(empty body)' : response.body;
      throw Exception('Device registration failed (${response.statusCode}): $body');
    }
  }

  Future<List<PendingDelivery>> listPendingDeliveries({required String recordId}) async {
    final uri = Uri.parse('${RecordStore.instance.serverUrl}/api/v1/records/$recordId/deliveries');
    final response = await _client
        .get(
          uri,
          headers: {'authorization': 'Bearer $recordId'},
        )
        .timeout(_timeout);

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body.isEmpty ? '(empty body)' : response.body;
      throw Exception('Delivery poll failed (${response.statusCode}): $body');
    }

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final deliveries = decoded['deliveries'] as List<dynamic>? ?? const [];

    return deliveries.map((entry) {
      final map = entry as Map<String, dynamic>;
      return PendingDelivery(
        deliveryId: map['delivery_id'] as String,
        envelope: Map<String, dynamic>.from(map['envelope'] as Map),
      );
    }).toList();
  }

  Future<void> ackDelivery({
    required String recordId,
    required String deliveryId,
  }) async {
    final uri = Uri.parse(
      '${RecordStore.instance.serverUrl}/api/v1/records/$recordId/deliveries/$deliveryId',
    );
    final response = await _client
        .delete(
          uri,
          headers: {'authorization': 'Bearer $recordId'},
        )
        .timeout(_timeout);

    if (response.statusCode != 204 && response.statusCode != 404) {
      final body = response.body.isEmpty ? '(empty body)' : response.body;
      throw Exception('Delivery ack failed (${response.statusCode}): $body');
    }
  }

  String deliveryWebSocketUrl(String recordId) {
    final base = Uri.parse(RecordStore.instance.serverUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/ws/delivery',
      queryParameters: {'token': recordId},
    ).toString();
  }
}
