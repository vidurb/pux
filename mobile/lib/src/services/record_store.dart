import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RecordStore {
  RecordStore._();

  static final RecordStore instance = RecordStore._();

  static const _recordIdKey = 'record_id';
  static const _privateKeyKey = 'private_key';
  static const _publicKeyKey = 'public_key';
  static const _inboxKey = 'inbox';
  static const _serverKey = 'server_url';
  static const _desktopDeviceIdKey = 'desktop_device_id';
  static const _deviceIdKey = 'device_id';
  static const _dismissedRestrictionPromptsKey =
      'dismissed_restriction_prompts';

  static const _cleartextHosts = {'localhost', '127.0.0.1', '10.0.2.2'};
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );

  // iOS: items land in the shared keychain group (the first entry of
  // keychain-access-groups in Runner.entitlements), so the notification
  // service extension can decrypt pushes, including while the phone is locked.
  // AppDelegate moves items written by older builds into that group.
  // Android: v11 custom-cipher storage. v11 dropped the v10 migration from
  // EncryptedSharedPreferences; no released build used that format.
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  late String _defaultServerUrl;
  late String serverUrl;

  /// Uses the server stored at enrollment, falling back to [serverUrl] (the
  /// compile-time default) when the device has not enrolled yet.
  Future<void> init({required String serverUrl}) async {
    _defaultServerUrl = serverUrl;
    final stored = await _storage.read(key: _serverKey);
    this.serverUrl = (stored != null && stored.isNotEmpty) ? stored : serverUrl;
  }

  @visibleForTesting
  void setServerUrlForTesting(String url) {
    _defaultServerUrl = url;
    serverUrl = url;
  }

  Future<bool> isEnrolled() async {
    final recordId = await _storage.read(key: _recordIdKey);
    final privateKey = await _storage.read(key: _privateKeyKey);
    final publicKey = await _storage.read(key: _publicKeyKey);
    return recordId != null && privateKey != null && publicKey != null;
  }

  Future<void> saveEnrollment(Map<String, dynamic> payload) async {
    _validateEnrollmentPayload(payload);
    final effectiveServer = enrollmentServer(payload);

    // The record ID goes last: isEnrolled needs it, so a partial save can never
    // look enrolled, even if the cleanup below fails too.
    final values = {
      _inboxKey: payload['inbox'] as String,
      _serverKey: effectiveServer,
      _publicKeyKey: payload['public_key'] as String,
      _privateKeyKey: payload['private_key'] as String,
      _recordIdKey: payload['record_id'] as String,
    };

    try {
      for (final MapEntry(:key, :value) in values.entries) {
        await _storage.write(key: key, value: value);
      }
    } catch (_) {
      for (final key in values.keys) {
        try {
          await _storage.delete(key: key);
        } catch (deleteError) {
          debugPrint('Could not clean up a partial enrollment: $deleteError');
        }
      }
      rethrow;
    }
    serverUrl = effectiveServer;
  }

  Future<String?> recordId() => _storage.read(key: _recordIdKey);
  Future<String?> privateKey() => _storage.read(key: _privateKeyKey);
  Future<String?> publicKey() => _storage.read(key: _publicKeyKey);
  Future<String?> inbox() => _storage.read(key: _inboxKey);

  /// The server's ID for this device's registration, for removing it later.
  Future<String?> deviceId() => _storage.read(key: _deviceIdKey);

  Future<void> saveDeviceId(String? deviceId) async {
    if (deviceId == null || deviceId.isEmpty) return;
    await _storage.write(key: _deviceIdKey, value: deviceId);
  }

  /// Which restriction prompts the user dismissed. [clear] forgets
  /// these along with the enrollment, so setting up again asks again.
  Future<Set<String>> dismissedRestrictionPrompts() async {
    final stored = await _storage.read(key: _dismissedRestrictionPromptsKey);
    if (stored == null || stored.isEmpty) return {};
    return stored.split(',').toSet();
  }

  Future<void> saveDismissedRestrictionPrompts(Set<String> names) => _storage
      .write(key: _dismissedRestrictionPromptsKey, value: names.join(','));

  /// The validated server an enrollment payload points at: its `server`, or
  /// the current one when absent. Throws [FormatException] if it is unsafe.
  String enrollmentServer(Map<String, dynamic> payload) {
    final server = payload['server'];
    if (server == null || (server is String && server.isEmpty)) {
      return serverUrl;
    }
    if (server is! String) {
      throw const FormatException('Invalid server in enrollment');
    }
    // The build's own default is trusted, so development builds can point anywhere.
    if (server == _defaultServerUrl) return server;
    return validateServerUrl(server);
  }

  /// Accepts https URLs, and plain http only for local development hosts.
  /// Returns the URL without a trailing slash.
  static String validateServerUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('Invalid server URL in enrollment');
    }
    final secure = uri.scheme == 'https';
    final local = uri.scheme == 'http' && _cleartextHosts.contains(uri.host);
    if (!secure && !local) {
      throw FormatException(
        'Refusing insecure server ${uri.scheme}://${uri.host}: https is required',
      );
    }
    if (uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.path.length > 1) {
      throw const FormatException(
        'Server URL must not have a path, query or credentials',
      );
    }
    return uri.replace(path: '').toString();
  }

  Future<String> desktopDeviceId() async {
    final existing = await _storage.read(key: _desktopDeviceIdKey);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final generated = _generateDesktopDeviceId();
    await _storage.write(key: _desktopDeviceIdKey, value: generated);
    return generated;
  }

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

  /// Forgets the enrollment (keys, record, server) on this device only.
  Future<void> clear() async {
    await _storage.deleteAll();
    serverUrl = _defaultServerUrl;
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
    final recordId = payload['record_id'];
    if (recordId is! String || !_uuid.hasMatch(recordId)) {
      throw const FormatException('Invalid record_id in enrollment');
    }
    if (payload['inbox'] is! String) {
      throw const FormatException('Invalid inbox in enrollment');
    }
    _decodeKey(payload['private_key'], field: 'private_key');
    _decodeKey(payload['public_key'], field: 'public_key');
    enrollmentServer(payload);
  }

  Uint8List _decodeKey(Object? value, {required String field}) {
    if (value is! String) throw FormatException('Missing $field');
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

  String _generateDesktopDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
