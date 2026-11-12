import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'record_store.dart';

class PendingDelivery {
  const PendingDelivery({required this.deliveryId, required this.envelope});

  final String deliveryId;
  final Map<String, dynamic> envelope;
}

/// The server no longer knows this record: it was deleted, pruned after going
/// 30 days with no devices, or never existed. Retrying will not help; the device
/// has to enroll again.
class RecordNotFoundException implements Exception {
  const RecordNotFoundException();

  @override
  String toString() => 'Relay not found on the server';
}

/// The record already has the maximum number of devices. Retrying will not
/// help until a device is removed from the relay.
class TooManyDevicesException implements Exception {
  const TooManyDevicesException();

  @override
  String toString() => 'This relay already has the maximum number of devices';
}

/// The server rate-limited the request (429). Transient; retry later.
class RateLimitedException implements Exception {
  const RateLimitedException();

  @override
  String toString() => 'The server is rate limiting requests';
}

/// The relay has no registered devices, so a test code has nowhere to go
/// (409 `no_devices`). Clears up once this device has registered.
class NoDevicesException implements Exception {
  const NoDevicesException();

  @override
  String toString() => 'No device is registered on this relay yet';
}

/// What `POST /record/test` sent: the code to look for, and how many devices
/// on the relay it went to.
@immutable
class TestCode {
  const TestCode({required this.otp, required this.devices});

  final String otp;
  final int devices;
}

enum ServerHealthState { reachable, unreachable, serverError }

/// The answer to `GET /health`. [reason] says why it isn't reachable.
@immutable
class ServerHealth {
  const ServerHealth(this.state, {this.reason});

  final ServerHealthState state;
  final String? reason;
}

class ApiClient {
  ApiClient._({http.Client? client}) : _client = client ?? http.Client();

  @visibleForTesting
  ApiClient.forTesting({http.Client? client})
    : _client = client ?? http.Client();

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

    _check(response, 'Record creation');

    final decoded = jsonDecode(response.body) as Map<String, dynamic>;
    final recordId = decoded['record_id'] as String?;
    final inboxAddress = decoded['inbox_address'] as String?;
    if (recordId == null || inboxAddress == null) {
      throw Exception('Record creation returned an incomplete response');
    }

    return {'record_id': recordId, 'inbox_address': inboxAddress};
  }

  /// Returns the server's device ID, used to remove this device later.
  Future<String?> registerDevice({
    required String recordId,
    required String pushToken,
    required String platform,
  }) async {
    final uri = Uri.parse(
      '${RecordStore.instance.serverUrl}/api/v1/record/devices',
    );
    final response = await _client
        .post(
          uri,
          headers: {
            'authorization': 'Bearer $recordId',
            'content-type': 'application/json',
          },
          body: jsonEncode({'push_token': pushToken, 'platform': platform}),
        )
        .timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 404) {
      throw const RecordNotFoundException();
    }
    if (response.statusCode == 422 &&
        _errorCode(response) == 'too_many_devices') {
      throw const TooManyDevicesException();
    }
    _check(response, 'Device registration');

    return _decodeObject(response)?['device_id'] as String?;
  }

  /// Removes one device from the record. A device or record the server no
  /// longer knows counts as removed.
  Future<void> deleteDevice({
    required String recordId,
    required String deviceId,
  }) async {
    final uri = Uri.parse(
      '${RecordStore.instance.serverUrl}/api/v1/record/devices/$deviceId',
    );
    final response = await _client
        .delete(uri, headers: {'authorization': 'Bearer $recordId'})
        .timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 404) return;
    _check(response, 'Device removal');
  }

  /// Deletes the record with all its devices and pending deliveries. A record
  /// the server no longer knows counts as deleted.
  Future<void> deleteRecord({required String recordId}) async {
    final uri = Uri.parse('${RecordStore.instance.serverUrl}/api/v1/record');
    final response = await _client
        .delete(uri, headers: {'authorization': 'Bearer $recordId'})
        .timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 404) return;
    _check(response, 'Relay deletion');
  }

  /// The server returns at most this many pending deliveries per request, oldest
  /// first, so a full page may have left newer ones out.
  static const pendingPageSize = 50;

  Future<List<PendingDelivery>> listPendingDeliveries({
    required String recordId,
  }) async {
    final uri = Uri.parse(
      '${RecordStore.instance.serverUrl}/api/v1/record/deliveries',
    );
    final response = await _client
        .get(uri, headers: {'authorization': 'Bearer $recordId'})
        .timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 404) {
      throw const RecordNotFoundException();
    }
    _check(response, 'Delivery poll');

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

  /// A delivery or record the server no longer knows counts as acknowledged.
  /// The next poll reports a record that is gone.
  Future<void> ackDelivery({
    required String recordId,
    required String deliveryId,
  }) async {
    final uri = Uri.parse(
      '${RecordStore.instance.serverUrl}/api/v1/record/deliveries/$deliveryId',
    );
    final response = await _client
        .delete(uri, headers: {'authorization': 'Bearer $recordId'})
        .timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 404) return;
    _check(response, 'Delivery ack');
  }

  /// Asks the server to send a made-up code to every device on the relay, by
  /// the same path as a real one, and returns it.
  Future<TestCode> sendTestCode({required String recordId}) async {
    final uri = Uri.parse(
      '${RecordStore.instance.serverUrl}/api/v1/record/test',
    );
    final response = await _client
        .post(uri, headers: {'authorization': 'Bearer $recordId'})
        .timeout(_timeout);

    if (response.statusCode == 401 || response.statusCode == 404) {
      throw const RecordNotFoundException();
    }
    if (response.statusCode == 409 && _errorCode(response) == 'no_devices') {
      throw const NoDevicesException();
    }
    _check(response, 'Test code');

    final decoded = _decodeObject(response);
    final otp = decoded?['otp'];
    final devices = decoded?['devices'];
    if (otp is! String || devices is! int) {
      throw Exception('Test code returned an incomplete response');
    }
    return TestCode(otp: otp, devices: devices);
  }

  static const healthTimeout = Duration(seconds: 10);

  /// Whether the server answers `GET /health` with `{"status":"ok"}`. Never
  /// throws: a failure is an answer too.
  Future<ServerHealth> checkHealth() async {
    final http.Response response;
    try {
      final uri = Uri.parse('${RecordStore.instance.serverUrl}/health');
      response = await _client.get(uri).timeout(healthTimeout);
    } on TimeoutException {
      return ServerHealth(
        ServerHealthState.unreachable,
        reason: 'no answer within ${healthTimeout.inSeconds} s',
      );
    } on http.ClientException catch (error) {
      return ServerHealth(ServerHealthState.unreachable, reason: error.message);
    } catch (error) {
      return ServerHealth(
        ServerHealthState.unreachable,
        reason: error.toString(),
      );
    }

    final status = _decodeObject(response)?['status'];
    if (response.statusCode == 200 && status == 'ok') {
      return const ServerHealth(ServerHealthState.reachable);
    }
    return ServerHealth(
      ServerHealthState.serverError,
      reason: switch (response.statusCode) {
        503 when status != null => 'its database is unavailable',
        200 => "the answer isn't from a pux server",
        final code => 'HTTP $code',
      },
    );
  }

  /// The record ID goes in the `x-pux-token` header, never the URL, so it
  /// stays out of proxy logs.
  String deliveryWebSocketUrl() {
    final base = Uri.parse(RecordStore.instance.serverUrl);
    final scheme = base.scheme == 'https' ? 'wss' : 'ws';
    return Uri(
      scheme: scheme,
      host: base.host,
      port: base.hasPort ? base.port : null,
      path: '/ws/delivery',
    ).toString();
  }

  void _check(http.Response response, String action) {
    if (response.statusCode == 429) throw const RateLimitedException();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = response.body.isEmpty ? '(empty body)' : response.body;
      throw Exception('$action failed (${response.statusCode}): $body');
    }
  }

  String? _errorCode(http.Response response) =>
      _decodeObject(response)?['error'] as String?;

  Map<String, dynamic>? _decodeObject(http.Response response) {
    try {
      final decoded = jsonDecode(response.body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }
}
