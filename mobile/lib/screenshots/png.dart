import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// Encodes RGBA pixels as a PNG with no alpha channel.
///
/// Google Play and App Store Connect both reject screenshots that have one,
/// and Flutter only encodes RGBA. The alpha byte is dropped, which for
/// premultiplied pixels (`ImageByteFormat.rawRgba`) is the same as drawing
/// them on black; the scenes are opaque anyway.
Uint8List encodeOpaquePng(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || rgba.length != width * height * 4) {
    throw ArgumentError('expected ${width}x$height RGBA pixels');
  }
  // Each row starts with its filter type: 0, none.
  final rows = Uint8List(height * (1 + width * 3));
  var out = 0;
  var input = 0;
  for (var y = 0; y < height; y++) {
    rows[out++] = 0;
    for (var x = 0; x < width; x++) {
      rows[out++] = rgba[input];
      rows[out++] = rgba[input + 1];
      rows[out++] = rgba[input + 2];
      input += 4;
    }
  }

  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8) // bits per channel
    ..setUint8(9, 2) // colour type: RGB
    ..setUint8(10, 0) // deflate
    ..setUint8(11, 0) // adaptive filtering
    ..setUint8(12, 0); // not interlaced

  final png = BytesBuilder(copy: false)
    ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  _chunk(png, 'IHDR', header.buffer.asUint8List());
  _chunk(png, 'IDAT', ZLibEncoder(level: 9).convert(rows));
  _chunk(png, 'IEND', const []);
  return png.takeBytes();
}

void _chunk(BytesBuilder png, String type, List<int> data) {
  final typed = [...type.codeUnits, ...data];
  final length = ByteData(4)..setUint32(0, data.length);
  final crc = ByteData(4)..setUint32(0, _crc32(typed));
  png
    ..add(length.buffer.asUint8List())
    ..add(typed)
    ..add(crc.buffer.asUint8List());
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return c ^ 0xFFFFFFFF;
}
