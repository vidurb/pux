import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'record_store.dart';

class CryptoService {
  CryptoService._();

  static final CryptoService instance = CryptoService._();

  Sodium? _sodium;

  Sodium get _lib {
    final sodium = _sodium;
    if (sodium == null) {
      throw StateError('CryptoService.init() has not completed');
    }
    return sodium;
  }

  Future<void> init() async {
    _sodium ??= await SodiumInit.init();
  }

  Future<Map<String, String>> generateKeyPair() async {
    final keyPair = _lib.crypto.box.keyPair();
    try {
      return {
        'public_key': encodeB64(keyPair.publicKey),
        'private_key': keyPair.secretKey.runUnlockedSync(
          (secret) => encodeB64(Uint8List.fromList(secret)),
        ),
      };
    } finally {
      keyPair.secretKey.dispose();
    }
  }

  Future<Map<String, dynamic>> decryptPayload(String ciphertextB64) async {
    final privateKeyB64 = await RecordStore.instance.privateKey();
    final publicKeyB64 = await RecordStore.instance.publicKey();
    if (privateKeyB64 == null || publicKeyB64 == null || publicKeyB64.isEmpty) {
      throw StateError('Device is not enrolled');
    }

    return openSealed(
      ciphertextB64: ciphertextB64,
      publicKeyB64: publicKeyB64,
      privateKeyB64: privateKeyB64,
    );
  }

  /// Opens a libsodium sealed box produced by the server (`:enacl.box_seal`),
  /// with keys and ciphertext in unpadded base64url.
  Map<String, dynamic> openSealed({
    required String ciphertextB64,
    required String publicKeyB64,
    required String privateKeyB64,
  }) {
    final publicKey = _decodeKey(publicKeyB64);
    final secretKey = _lib.secureCopy(_decodeKey(privateKeyB64));
    try {
      final plaintext = _lib.crypto.box.sealOpen(
        cipherText: decodeB64(ciphertextB64),
        publicKey: publicKey,
        secretKey: secretKey,
      );
      return jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
    } finally {
      secretKey.dispose();
    }
  }

  Uint8List _decodeKey(String value) {
    final decoded = decodeB64(value);
    if (decoded.length != 32) {
      throw const FormatException('Invalid key length');
    }
    return decoded;
  }

  static String encodeB64(Uint8List bytes) => base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List decodeB64(String value) =>
      Uint8List.fromList(base64Url.decode(base64Url.normalize(value)));
}
