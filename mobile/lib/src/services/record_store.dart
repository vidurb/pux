import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RecordStore {
  RecordStore._();

  static final RecordStore instance = RecordStore._();

  static const _recordIdKey = 'record_id';
  static const _privateKeyKey = 'private_key';
  static const _publicKeyKey = 'public_key';
  static const _inboxKey = 'inbox';
  static const _serverKey = 'server_url';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  late String serverUrl;

  Future<void> init({required String serverUrl}) async {
    this.serverUrl = serverUrl;
  }

  Future<bool> isEnrolled() async {
    final recordId = await _storage.read(key: _recordIdKey);
    final privateKey = await _storage.read(key: _privateKeyKey);
    return recordId != null && privateKey != null;
  }

  Future<void> saveEnrollment(Map<String, dynamic> payload) async {
    await _storage.write(key: _recordIdKey, value: payload['record_id'] as String);
    await _storage.write(key: _privateKeyKey, value: payload['private_key'] as String);
    await _storage.write(
      key: _publicKeyKey,
      value: payload['public_key'] as String? ?? '',
    );
    await _storage.write(key: _inboxKey, value: payload['inbox'] as String);
    await _storage.write(
      key: _serverKey,
      value: payload['server'] as String? ?? serverUrl,
    );
  }

  Future<String?> recordId() => _storage.read(key: _recordIdKey);
  Future<String?> privateKey() => _storage.read(key: _privateKeyKey);
  Future<String?> publicKey() => _storage.read(key: _publicKeyKey);
  Future<String?> inbox() => _storage.read(key: _inboxKey);

  Future<Map<String, dynamic>> enrollmentPayload() async {
    return {
      'v': 1,
      'record_id': await recordId(),
      'private_key': await privateKey(),
      'public_key': await _storage.read(key: _publicKeyKey),
      'inbox': await inbox(),
      'server': await _storage.read(key: _serverKey) ?? serverUrl,
    };
  }

  Future<void> clear() async {
    await _storage.deleteAll();
  }

  Map<String, dynamic> parseQr(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid QR payload');
    }
    if (decoded['v'] != 1) {
      throw const FormatException('Unsupported QR version');
    }
    _requiredKeys(decoded, ['record_id', 'private_key', 'inbox']);
    return decoded;
  }

  void _requiredKeys(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (map[key] == null || map[key].toString().isEmpty) {
        throw FormatException('Missing $key in QR payload');
      }
    }
  }
}
