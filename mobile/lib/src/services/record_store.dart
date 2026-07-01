import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RecordStore {
  RecordStore._();

  static final RecordStore instance = RecordStore._();

  static const _recordIdKey = 'record_id';
  static const _privateKeyKey = 'private_key';
  static const _publicKeyKey = 'public_key';
  static const _inboxKey = 'inbox';
  static const _serverKey = 'server_url';

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );
  late String serverUrl;

  Future<void> init({required String serverUrl}) async {
    this.serverUrl = serverUrl;
  }

  Future<bool> isEnrolled() async {
    final recordId = await _storage.read(key: _recordIdKey);
    final privateKey = await _storage.read(key: _privateKeyKey);
    final publicKey = await _storage.read(key: _publicKeyKey);
    return recordId != null && privateKey != null && publicKey != null;
  }

  Future<void> saveEnrollment(Map<String, dynamic> payload) async {
    _validateEnrollmentPayload(payload);

    await _storage.write(key: _recordIdKey, value: payload['record_id'] as String);
    await _storage.write(key: _privateKeyKey, value: payload['private_key'] as String);
    await _storage.write(key: _publicKeyKey, value: payload['public_key'] as String);
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
      'public_key': await publicKey(),
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
    _requiredKeys(decoded, ['record_id', 'private_key', 'public_key', 'inbox']);
    _validateEnrollmentPayload(decoded);
    return decoded;
  }

  void _requiredKeys(Map<String, dynamic> map, List<String> keys) {
    for (final key in keys) {
      if (map[key] == null || map[key].toString().isEmpty) {
        throw FormatException('Missing $key in QR payload');
      }
    }
  }

  void _validateEnrollmentPayload(Map<String, dynamic> payload) {
    _decodeKey(payload['private_key'] as String, field: 'private_key');
    _decodeKey(payload['public_key'] as String, field: 'public_key');
  }

  Uint8List _decodeKey(String value, {required String field}) {
    try {
      final decoded = base64Url.decode(_pad(value));
      if (decoded.length != 32) {
        throw FormatException('Invalid $field length');
      }
      return Uint8List.fromList(decoded);
    } on FormatException {
      rethrow;
    } catch (_) {
      throw FormatException('Invalid $field encoding');
    }
  }

  String _pad(String value) {
    final mod = value.length % 4;
    if (mod == 0) return value;
    return value.padRight(value.length + (4 - mod), '=');
  }
}
