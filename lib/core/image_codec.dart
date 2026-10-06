// Image encode/decode helpers bridging RgbaImage and opencv_dart.
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later)
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'perspective.dart';

/// Encodes an RGBA image to JPEG bytes via opencv imencode.
Uint8List encodeJpegBytes(RgbaImage img, {int quality = 92}) {
  final src = cv.Mat.fromList(img.height, img.width, cv.MatType.CV_8UC4, img.bytes);
  try {
    final bgr = cv.cvtColor(src, cv.COLOR_RGBA2BGR);
    try {
      final (ok, buf) = cv.imencode('.jpg', bgr, params: cv.VecI32.fromList([cv.IMWRITE_JPEG_QUALITY, quality]));
      if (!ok) throw StateError('jpeg encode failed');
      return buf;
    } finally {
      bgr.dispose();
    }
  } finally {
    src.dispose();
  }
}

/// Encodes an RGBA image to PNG bytes via opencv imencode.
Uint8List encodePngBytes(RgbaImage img) {
  final src = cv.Mat.fromList(img.height, img.width, cv.MatType.CV_8UC4, img.bytes);
  try {
    final (ok, buf) = cv.imencode('.png', src);
    if (!ok) throw StateError('png encode failed');
    return buf;
  } finally {
    src.dispose();
  }
}

/// Decodes image bytes (JPEG/PNG) into an RGBA image.
RgbaImage decodeImageBytes(Uint8List bytes) {
  final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
  try {
    final rgba = cv.cvtColor(mat, cv.COLOR_BGR2RGBA);
    try {
      return RgbaImage(Uint8List.fromList(rgba.data), rgba.cols, rgba.rows);
    } finally {
      rgba.dispose();
    }
  } finally {
    mat.dispose();
  }
}

/// Downscales an RGBA image so its longest side is at most [maxSide].
/// Pure Dart (no native binding) so it is safe to call inside an isolate.
RgbaImage thumbOf(RgbaImage src, int maxSide) {
  final scale = maxSide / (src.width > src.height ? src.width : src.height);
  if (scale >= 1) return src;
  final w = (src.width * scale).round(), h = (src.height * scale).round();
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final sy = (y / scale).round().clamp(0, src.height - 1);
    for (var x = 0; x < w; x++) {
      final sx = (x / scale).round().clamp(0, src.width - 1);
      final so = (sy * src.width + sx) * 4;
      final o = (y * w + x) * 4;
      out[o] = src.bytes[so]; out[o + 1] = src.bytes[so + 1];
      out[o + 2] = src.bytes[so + 2]; out[o + 3] = 255;
    }
  }
  return RgbaImage(out, w, h);
}
