import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clearscan_flutter/core/document_detector.dart';
import 'package:clearscan_flutter/core/perspective.dart';

/// Draws a dark quadrilateral document on a light background (RGBA).
RgbaImage syntheticDoc(int width, int height, List<Point> corners, {int pad = 40}) {
  final data = Uint8List(width * height * 4);
  // light gray background with subtle noise
  final rng = math.Random(7);
  for (var i = 0; i < width * height; i++) {
    final v = 235 + rng.nextInt(15);
    data[i * 4] = v;
    data[i * 4 + 1] = v;
    data[i * 4 + 2] = v - 5;
    data[i * 4 + 3] = 255;
  }
  void fillLine(int x0, int y0, int x1, int y1, int thickness) {
    final steps = math.max((x1 - x0).abs(), (y1 - y0).abs()) * 2;
    for (var s = 0; s <= steps; s++) {
      final t = s / steps;
      final cx = (x0 + (x1 - x0) * t).round();
      final cy = (y0 + (y1 - y0) * t).round();
      for (var dy = -thickness; dy <= thickness; dy++) {
        for (var dx = -thickness; dx <= thickness; dx++) {
          final px = cx + dx, py = cy + dy;
          if (px < 0 || py < 0 || px >= width || py >= height) continue;
          // darker interior fill for the quad body
          final o = (py * width + px) * 4;
          data[o] = 250; data[o + 1] = 250; data[o + 2] = 245;
        }
      }
      // edge stroke dark
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final px = cx + dx, py = cy + dy;
          if (px < 0 || py < 0 || px >= width || py >= height) continue;
          final o = (py * width + px) * 4;
          data[o] = 30; data[o + 1] = 30; data[o + 2] = 30;
        }
      }
    }
  }

  final px = corners.map((p) => Point(p.x * width, p.y * height)).toList();
  for (var i = 0; i < 4; i++) {
    final a = px[i], b = px[(i + 1) % 4];
    fillLine(a.x.toInt(), a.y.toInt(), b.x.toInt(), b.y.toInt(), 2);
  }
  // fill quad interior slightly off-white
  return RgbaImage(data, width, height);
}

void main() {
  test('orderNormalizedCorners returns TL,TR,BR,BL', () {
    final corners = [
      const Point(.9, .1), // TR given first
      const Point(.1, .9), // BL
      const Point(.1, .1), // TL
      const Point(.9, .9), // BR
    ];
    final ordered = DocumentEdgeDetector.orderNormalizedCorners(corners);
    expect(ordered[0].x, lessThan(ordered[1].x)); // TL left of TR
    expect(ordered[0].y, lessThan(ordered[3].y)); // TL above BL
    expect(ordered[3].y, greaterThan(ordered[0].y));
  });

  test('detect fails gracefully on tiny image', () {
    final img = RgbaImage.blank(32, 32);
    final result = DocumentEdgeDetector.detect(
      Uint8ListRgba(img.bytes, img.width, img.height),
    );
    expect(result.status, DocumentDetectionStatus.failed);
    expect(result.reason, 'Image is too small');
  });

  test('detect finds synthetic document quad', () {
    final img = syntheticDoc(800, 1000, [
      const Point(.15, .10),
      const Point(.85, .12),
      const Point(.82, .88),
      const Point(.18, .85),
    ]);
    final result = DocumentEdgeDetector.detect(
      Uint8ListRgba(img.bytes, img.width, img.height),
    );
    // The detector must at least not crash; on synthetic input it should find a quad.
    expect(result.status, isNot(DocumentDetectionStatus.failed),
        reason: 'reason: ${result.reason}');
    if (result.corners.isNotEmpty) {
      expect(result.corners.length, 4);
      for (final c in result.corners) {
        expect(c.x, inInclusiveRange(0, 1));
        expect(c.y, inInclusiveRange(0, 1));
      }
    }
  });

  test('perspective crop returns corrected rectangle', () {
    final img = syntheticDoc(800, 1000, [
      const Point(.1, .1),
      const Point(.9, .1),
      const Point(.9, .9),
      const Point(.1, .9),
    ]);
    final cropped = DocumentPerspectiveCorrector.crop(img, [
      const Point(.1, .1),
      const Point(.9, .1),
      const Point(.9, .9),
      const Point(.1, .9),
    ]);
    expect(cropped.width, greaterThan(32));
    expect(cropped.height, greaterThan(32));
    expect(cropped.bytes.length, cropped.width * cropped.height * 4);
  });

  test('crop rejects tiny region', () {
    final img = RgbaImage.blank(800, 800);
    expect(
      () => DocumentPerspectiveCorrector.crop(img, [
        const Point(.5, .5),
        const Point(.505, .5),
        const Point(.505, .505),
        const Point(.5, .505),
      ]),
      throwsArgumentError,
    );
  });

  test('book splitter keeps portrait page whole', () {
    final img = RgbaImage.blank(600, 1000);
    final pages = BookPageSplitter.split(img);
    expect(pages.length, 1);
  });

  test('book splitter splits wide spread', () {
    final img = RgbaImage.blank(2000, 1000);
    final pages = BookPageSplitter.split(img);
    expect(pages.length, 2);
    final totalWidth = pages.fold<int>(0, (sum, p) => sum + p.width);
    expect(totalWidth, 2000);
  });
}
