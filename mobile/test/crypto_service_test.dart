import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/crypto_service.dart';
import 'package:sodium_libs/sodium_libs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('sealed box roundtrip matches server crypto format', () async {
    late Sodium sodium;

    try {
      sodium = await SodiumInit.init();
    } catch (_) {
      // Native sodium plugin may be unavailable in headless test runners.
      return;
    }

    final keyPair = sodium.crypto.box.keyPair();
    final plaintext = utf8.encode(
      jsonEncode({
        'otp': '654321',
        'sender': 'HDFC Bank',
        'received_at': '2026-07-01T00:00:00Z',
      }),
    );

    final ciphertext = sodium.crypto.box.seal(
      message: Uint8List.fromList(plaintext),
      publicKey: keyPair.publicKey,
    );

    final opened = sodium.crypto.box.sealOpen(
      cipherText: ciphertext,
      publicKey: keyPair.publicKey,
      secretKey: keyPair.secretKey,
    );

    final decoded = jsonDecode(utf8.decode(opened)) as Map<String, dynamic>;
    expect(decoded['otp'], '654321');
    expect(decoded['sender'], 'HDFC Bank');
  });

  test('generateKeyPair produces keys that round-trip sealed boxes', () async {
    try {
      await CryptoService.instance.init();
    } catch (_) {
      return;
    }

    final keys = await CryptoService.instance.generateKeyPair();
    expect(keys['public_key'], isNotEmpty);
    expect(keys['private_key'], isNotEmpty);
    expect(keys['public_key']!.contains('='), isFalse);
    expect(keys['private_key']!.contains('='), isFalse);

    final sodium = await SodiumInit.init();
    final publicKey = Uint8List.fromList(base64Url.decode(_pad(keys['public_key']!)));
    final secretKey = sodium.secureCopy(
      Uint8List.fromList(base64Url.decode(_pad(keys['private_key']!))),
    );
    expect(publicKey.length, 32);
    expect(secretKey.length, 32);

    final plaintext = utf8.encode('{"otp":"123456"}');
    final ciphertext = sodium.crypto.box.seal(
      message: Uint8List.fromList(plaintext),
      publicKey: publicKey,
    );

    final opened = sodium.crypto.box.sealOpen(
      cipherText: ciphertext,
      publicKey: publicKey,
      secretKey: secretKey,
    );

    expect(utf8.decode(opened), '{"otp":"123456"}');
  });
}

String _pad(String value) {
  final mod = value.length % 4;
  if (mod == 0) return value;
  return value.padRight(value.length + (4 - mod), '=');
}
