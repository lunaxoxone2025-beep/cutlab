import 'dart:typed_data';

import 'media_engine.dart';

/// Wraps RGBA pixels in an uncompressed 24-bit BMP so they can be shown with
/// Image.memory (and cached as plain bytes) without an image encoder.
Uint8List encodeBmp(RgbaImage img) {
  const header = 14 + 40; // BITMAPFILEHEADER + BITMAPINFOHEADER
  final rowBytes = (img.width * 3 + 3) & ~3; // rows are padded to 4 bytes
  final size = header + rowBytes * img.height;
  final out = Uint8List(size);
  final d = ByteData.sublistView(out);
  out[0] = 0x42; // 'B'
  out[1] = 0x4D; // 'M'
  d.setUint32(2, size, Endian.little);
  d.setUint32(10, header, Endian.little);
  d.setUint32(14, 40, Endian.little);
  d.setInt32(18, img.width, Endian.little);
  d.setInt32(22, -img.height, Endian.little); // negative height = top-down rows
  d.setUint16(26, 1, Endian.little); // planes
  d.setUint16(28, 24, Endian.little); // bits per pixel
  d.setUint32(30, 0, Endian.little); // BI_RGB
  d.setUint32(34, rowBytes * img.height, Endian.little);
  final px = img.pixels;
  for (var y = 0; y < img.height; y++) {
    var o = header + y * rowBytes;
    var i = y * img.width * 4;
    for (var x = 0; x < img.width; x++) {
      out[o] = px[i + 2]; // B
      out[o + 1] = px[i + 1]; // G
      out[o + 2] = px[i]; // R
      o += 3;
      i += 4;
    }
  }
  return out;
}
