import 'dart:convert';

import 'package:http/http.dart' as http;

import 'record_store.dart';

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  static const _timeout = Duration(seconds: 15);

  Future<Map<String, String>> createRecord({required String publicKey}) async {
    final uri = Uri.parse('${RecordStore.instance.serverUrl}/api/v1/records');
    final response = await http
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
    final response = await http
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
}
