import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pux/src/services/crypto_service.dart';
import 'package:sodium/sodium.dart';

// Sealed by the server's own `:enacl.box_seal/2` (projects/pux/server
// lib/pux/crypto.ex), encoded the same way the server encodes keys and
// ciphertext: unpadded base64url.
const _fixturePublicKey = 'oVaRfoaaBI7h10MCUauxYiPWaLQaAjN_oklwaOO682M';
const _fixturePrivateKey = '3h7LhAw9e7EtYS5TeRJsQqYI8v4LtpH49buqnScv9qU';
const _fixtureCiphertext =
    '-h4t5FOku-OWtLBcg4jo8jCNDVhdUtGyVWDk4z_FmFAI46lEoMhWZkF76pcW6lcgJI9UJ8a8JQM-'
    'K3WA0vt7dXtlqXAKJwQfJ17REgKjSEVqOSjmmBpTmUcPtt_qHLCpMdk';

// Fixture published with the server's typed-payload change (vidurb/pux#2).
const _serverPrPublicKey = '6_SQ3WcbCBRRy0xu9yCMatZKbk29McalZTBo3gGzplw';
const _serverPrSecretKey = 'vfIJ42agVVRyDVVmTMtIHPL02MMvNyXMuYf8BgviqDI';
const _serverPrCiphertext =
    'Xso7kEp1NhYtxtQC5hMfioNb2Q3_Y3KadFsVXxDtJRJ3KVUY_KqedKRIW-w4kMKf8SHpQ3FYbIJ7T8cM5LM-'
    'tCLJrk6Dyqe1J60Fu13SM6Ci1fISV_VAN9fI0WxPAdzUOBLSqhoVNlmvDg60KTX6k-ubO7gtRDmh8Jit8g3O'
    'MYhKV_KLn45FJKGjqF5ERXM6cmyCouvd2feDRw';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // No try/catch: if libsodium cannot load, these tests must fail, not skip.
  setUpAll(() => CryptoService.instance.init());

  test('opens a sealed box produced by the server', () {
    final payload = CryptoService.instance.openSealed(
      ciphertextB64: _fixtureCiphertext,
      publicKeyB64: _fixturePublicKey,
      privateKeyB64: _fixturePrivateKey,
    );

    expect(payload, {'type': 'otp', 'otp': '482913', 'sender': 'HDFC Bank'});
  });

  test('opens the typed payload fixture from the server', () {
    final payload = CryptoService.instance.openSealed(
      ciphertextB64: _serverPrCiphertext,
      publicKeyB64: _serverPrPublicKey,
      privateKeyB64: _serverPrSecretKey,
    );

    expect(payload, {
      'type': 'otp',
      'otp': '123456',
      'sender': 'Test Bank',
      'received_at': '2026-10-06T00:00:00Z',
      'parser': 'generic',
    });
  });

  test('rejects a ciphertext sealed for a different key', () async {
    final other = await CryptoService.instance.generateKeyPair();

    expect(
      () => CryptoService.instance.openSealed(
        ciphertextB64: _fixtureCiphertext,
        publicKeyB64: other['public_key']!,
        privateKeyB64: other['private_key']!,
      ),
      throwsA(isA<SodiumException>()),
    );
  });

  test('generated keypairs are unpadded base64url and open sealed boxes', () async {
    final keys = await CryptoService.instance.generateKeyPair();
    expect(keys['public_key']!.contains('='), isFalse);
    expect(keys['private_key']!.contains('='), isFalse);
    expect(CryptoService.decodeB64(keys['public_key']!).length, 32);
    expect(CryptoService.decodeB64(keys['private_key']!).length, 32);

    final sodium = await SodiumInit.init();
    final sealed = sodium.crypto.box.seal(
      message: Uint8List.fromList(utf8.encode('{"otp":"123456"}')),
      publicKey: CryptoService.decodeB64(keys['public_key']!),
    );

    final payload = CryptoService.instance.openSealed(
      ciphertextB64: CryptoService.encodeB64(sealed),
      publicKeyB64: keys['public_key']!,
      privateKeyB64: keys['private_key']!,
    );
    expect(payload['otp'], '123456');
  });
}
