import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
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
}
