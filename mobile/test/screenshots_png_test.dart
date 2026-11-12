import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:pux/screenshots/png.dart';

void main() {
  // 2 x 2: red, green / blue, half-transparent white.
  final rgba = Uint8List.fromList([
    255, 0, 0, 255, 0, 255, 0, 255, //
    0, 0, 255, 255, 128, 128, 128, 128,
  ]);

  test('writes an RGB PNG with no alpha channel', () {
    final png = encodeOpaquePng(rgba, 2, 2);
    final data = ByteData.sublistView(png);

    expect(png.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    expect(String.fromCharCodes(png.sublist(12, 16)), 'IHDR');
    expect(data.getUint32(16), 2);
    expect(data.getUint32(20), 2);
    expect(png[24], 8, reason: 'bit depth');
    expect(png[25], 2, reason: 'colour type RGB, no alpha');

    final idatLength = data.getUint32(33);
    expect(String.fromCharCodes(png.sublist(37, 41)), 'IDAT');
    final rows = ZLibDecoder().convert(png.sublist(41, 41 + idatLength));
    expect(rows, [0, 255, 0, 0, 0, 255, 0, 0, 0, 0, 255, 128, 128, 128]);

    // IEND has no data, so its CRC is always the same.
    expect(png.sublist(png.length - 8), [
      0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, //
    ]);
  });

  test('decodes with the engine', () async {
    final codec = await ui.instantiateImageCodec(encodeOpaquePng(rgba, 2, 2));
    final image = (await codec.getNextFrame()).image;
    final pixels = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    expect(pixels!.buffer.asUint8List(), [
      255, 0, 0, 255, 0, 255, 0, 255, //
      0, 0, 255, 255, 128, 128, 128, 255,
    ]);
  });

  test('rejects a buffer of the wrong size', () {
    expect(() => encodeOpaquePng(Uint8List(12), 2, 2), throwsArgumentError);
  });
}
