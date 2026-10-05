// Dart port of DocumentPerspectiveCorrector.kt + BookPageSplitter.kt
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'document_detector.dart';

class RgbaImage {
  final Uint8List bytes; // RGBA8888
  final int width;
  final int height;
  const RgbaImage(this.bytes, this.width, this.height);

  static RgbaImage blank(int width, int height, [int r = 255, int g = 255, int b = 255]) {
    final data = Uint8List(width * height * 4);
    for (var i = 0; i < width * height; i++) {
      data[i * 4] = r;
      data[i * 4 + 1] = g;
      data[i * 4 + 2] = b;
      data[i * 4 + 3] = 255;
    }
    return RgbaImage(data, width, height);
  }
}

class DocumentPerspectiveCorrector {
  static const int _maxOutputLongSide = 4096;

  static RgbaImage crop(RgbaImage bitmap, List<Point> normalizedCorners) {
    if (normalizedCorners.length != 4) {
      throw ArgumentError('Four crop corners are required');
    }
    final ordered = DocumentEdgeDetector.orderNormalizedCorners(normalizedCorners);
    final points = ordered
        .map((p) => cv.Point(
              (p.x.clamp(0.0, 1.0) * (bitmap.width - 1)).toInt(),
              (p.y.clamp(0.0, 1.0) * (bitmap.height - 1)).toInt(),
            ))
        .toList();
    double dist(cv.Point a, cv.Point b) =>
        math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));
    final measuredWidth = math.max(dist(points[0], points[1]), dist(points[3], points[2]));
    final measuredHeight = math.max(dist(points[0], points[3]), dist(points[1], points[2]));
    if (measuredWidth < 32.0 || measuredHeight < 32.0) {
      throw ArgumentError('Crop area is too small');
    }
    final outputScale =
        math.min(1.0, _maxOutputLongSide / math.max(measuredWidth, measuredHeight));
    final outputWidth = math.max(32, (measuredWidth * outputScale).toInt());
    final outputHeight = math.max(32, (measuredHeight * outputScale).toInt());

    final source = cv.Mat.fromList(bitmap.height, bitmap.width, cv.MatType.CV_8UC4, bitmap.bytes);
    try {
      final src = cv.VecPoint.fromList(points);
      final dst = cv.VecPoint.fromList([
        cv.Point(0, 0),
        cv.Point(outputWidth - 1, 0),
        cv.Point(outputWidth - 1, outputHeight - 1),
        cv.Point(0, outputHeight - 1),
      ]);
      final transform = cv.getPerspectiveTransform(src, dst);
      try {
        final output = cv.warpPerspective(
          source,
          transform,
          (outputWidth, outputHeight),
          flags: cv.INTER_CUBIC,
          borderMode: cv.BORDER_CONSTANT,
          borderValue: cv.Scalar(255, 255, 255, 255),
        );
        return RgbaImage(Uint8List.fromList(output.data), outputWidth, outputHeight);
      } finally {
        transform.dispose();
        src.dispose();
        dst.dispose();
      }
    } finally {
      source.dispose();
    }
  }
}

class BookPageSplitter {
  static List<RgbaImage> split(RgbaImage bitmap) {
    if (bitmap.width < bitmap.height * .82) return [bitmap];
    final start = (bitmap.width * .34).toInt();
    final end = (bitmap.width * .66).toInt();
    final stepY = math.max(1, bitmap.height ~/ 240);
    var bestX = bitmap.width ~/ 2;
    var bestScore = double.maxFinite;
    for (var x = start; x <= end; x += math.max(1, bitmap.width ~/ 400)) {
      double gray(int px) {
        final o = px * 4;
        return bitmap.bytes[o] * .299 + bitmap.bytes[o + 1] * .587 + bitmap.bytes[o + 2] * .114;
      }

      var luminance = 0.0;
      var edge = 0.0;
      var count = 0;
      for (var y = 0; y < bitmap.height; y += stepY) {
        final current = gray(x);
        final left = gray(math.max(0, x - 3));
        luminance += current;
        edge += (current - left).abs();
        count++;
      }
      final average = luminance / math.max(1, count);
      final edgeAverage = edge / math.max(1, count);
      final centerPenalty = (x - bitmap.width / 2.0).abs() / bitmap.width * 24.0;
      final score = average * .65 - edgeAverage * .35 + centerPenalty;
      if (score < bestScore) {
        bestScore = score;
        bestX = x;
      }
    }
    if (bestX < bitmap.width * .28 || bestX > bitmap.width * .72) bestX = bitmap.width ~/ 2;

    RgbaImage slice(int x0, int x1) {
      final w = x1 - x0;
      final out = Uint8List(w * bitmap.height * 4);
      for (var y = 0; y < bitmap.height; y++) {
        final srcOff = (y * bitmap.width + x0) * 4;
        final dstOff = y * w * 4;
        out.setRange(dstOff, dstOff + w * 4, bitmap.bytes, srcOff);
      }
      return RgbaImage(out, w, bitmap.height);
    }

    return [slice(0, bestX), slice(bestX, bitmap.width)];
  }
}

/// Rotates an RGBA image by 90-degree quarter turns (clockwise).
RgbaImage rotateQuarters(RgbaImage src, int quarters) {
  var q = quarters % 4;
  if (q < 0) q += 4;
  var img = src;
  for (var i = 0; i < q; i++) {
    final w = img.width, h = img.height;
    final out = Uint8List(w * h * 4);
    // new width = old height, new height = old width
    final ow = h, oh = w;
    for (var y = 0; y < oh; y++) {
      for (var x = 0; x < ow; x++) {
        // clockwise: dst(x,y) = src(y, oh-1-x)? For 90° CW: dst[x][y] = src[h-1-y][x]
        final so = ((h - 1 - x) * w + y) * 4;
        final o = (y * ow + x) * 4;
        out[o] = img.bytes[so];
        out[o + 1] = img.bytes[so + 1];
        out[o + 2] = img.bytes[so + 2];
        out[o + 3] = img.bytes[so + 3];
      }
    }
    img = RgbaImage(out, ow, oh);
  }
  return img;
}
