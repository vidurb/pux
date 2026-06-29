import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart';

import 'record_store.dart';

class CryptoService {
  CryptoService._();

  static final CryptoService instance = CryptoService._();

  late Sodium _sodium;

  Future<void> init() async {
    _sodium = await SodiumInit.init();
  }

  Future<Map<String, dynamic>> decryptPayload(String ciphertextB64) async {
    final privateKeyB64 = await RecordStore.instance.privateKey();
    final publicKeyB64 = await RecordStore.instance.publicKey();
    if (privateKeyB64 == null || publicKeyB64 == null || publicKeyB64.isEmpty) {
      throw StateError('Device is not enrolled');
    }

    final publicKey = _decodeKey(publicKeyB64);
    final secretKey = _sodium.secureCopy(_decodeKey(privateKeyB64));
    final ciphertext = _decodeB64(ciphertextB64);

    final plaintext = _sodium.crypto.box.sealOpen(
      cipherText: ciphertext,
      publicKey: publicKey,
      secretKey: secretKey,
    );

    return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
  }

  Uint8List _decodeKey(String value) {
    final decoded = base64Url.decode(_pad(value));
    if (decoded.length != 32) {
      throw const FormatException('Invalid key length');
    }
    return Uint8List.fromList(decoded);
  }

  Uint8List _decodeB64(String value) => Uint8List.fromList(base64Url.decode(_pad(value)));

  String _pad(String value) {
    final mod = value.length % 4;
    if (mod == 0) return value;
    return value.padRight(value.length + (4 - mod), '=');
  }
}
