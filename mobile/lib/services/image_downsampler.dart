import 'dart:typed_data';

import 'package:image/image.dart' as img;

abstract final class ImageDownsampler {
  static Future<Uint8List> sanitize(Uint8List bytes) async {
    if (bytes.length > 50 * 1024 * 1024) {
      throw StateError('Image input exceeds 50 MB');
    }
    final decoder = img.findDecoderForData(bytes);
    final info = decoder?.startDecode(bytes);
    if (info == null || info.width * info.height > 45000000) {
      throw StateError('Invalid image or image exceeds 45 MP');
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) throw StateError('Image decoding failed');
    var image = img.bakeOrientation(decoded);
    if (image.width > 2000 || image.height > 2000) {
      image = img.copyResize(
        image,
        width: image.width >= image.height ? 2000 : null,
        height: image.height > image.width ? 2000 : null,
      );
    }
    final clean = img.Image(
      width: image.width,
      height: image.height,
      numChannels: 3,
    );
    img.fill(clean, color: img.ColorRgb8(255, 255, 255));
    img.compositeImage(clean, image);
    return Uint8List.fromList(img.encodeJpg(clean, quality: 90));
  }
}
