import 'dart:convert';

import 'package:http/http.dart' as http;

import 'record_store.dart';

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  static const _timeout = Duration(seconds: 15);

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
