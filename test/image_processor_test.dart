import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:clearscan_flutter/core/perspective.dart';
import 'package:clearscan_flutter/core/image_processor.dart';

/// Synthetic "document": white paper with dark text strokes and a slight color cast.
RgbaImage syntheticDocImage({int width = 400, int height = 300, bool warm = true}) {
  final data = Uint8List(width * height * 4);
  final rng = math.Random(42);
  for (var i = 0; i < width * height; i++) {
    // paper with cast: warm = reddish paper (color cast to be removed by gray-world)
    final base = 225 + rng.nextInt(20);
    data[i * 4] = warm ? base : base - 8;
    data[i * 4 + 1] = base - (warm ? 10 : 0);
    data[i * 4 + 2] = warm ? base - 22 : base - 4;
    data[i * 4 + 3] = 255;
  }
  // draw "text": dark horizontal strokes
  final rngStroke = math.Random(7);
  for (var line = 0; line < 8; line++) {
    final y = 30 + line * 30;
    var x = 30;
    while (x < width - 30) {
      final len = 20 + rngStroke.nextInt(60);
      for (var dx = 0; dx < len && x + dx < width - 30; dx++) {
        for (var dy = -2; dy <= 2; dy++) {
          final o = ((y + dy) * width + (x + dx)) * 4;
          data[o] = 30; data[o + 1] = 28; data[o + 2] = 26;
        }
      }
      x += len + 10 + rngStroke.nextInt(20);
    }
  }
  return RgbaImage(data, width, height);
}

void main() {
  test('adjust applies brightness/contrast/saturation', () {
    final img = syntheticDocImage();
    final adjusted = ImageProcessor.adjust(img, .025, 1.14, 1.0)!;
    expect(adjusted.width, img.width);
    expect(adjusted.height, img.height);
    // contrast 1.14 should expand values: some pixel must hit the bounds
    var hasDark = false, hasBright = false;
    for (var i = 0; i < adjusted.bytes.length; i += 4) {
      if (adjusted.bytes[i] < 20) hasDark = true;
      if (adjusted.bytes[i] > 250) hasBright = true;
    }
    expect(hasDark || hasBright, isTrue, reason: 'contrast should stretch range');
  });

  test('sharpen increases local contrast at edges', () {
    final img = syntheticDocImage();
    final sharpened = ImageProcessor.sharpen(img, amount: 1.0);
    expect(sharpened.width, img.width);
    // unsharp must push the darkest ink darker (overshoot) or keep it, never lighten the whole image
    int minOf(RgbaImage im) {
      var m = 255;
      for (var i = 0; i < im.bytes.length; i += 4) {
        if (im.bytes[i] < m) m = im.bytes[i];
      }
      return m;
    }
    int maxOf(RgbaImage im) {
      var m = 0;
      for (var i = 0; i < im.bytes.length; i += 4) {
        if (im.bytes[i] > m) m = im.bytes[i];
      }
      return m;
    }
    expect(minOf(sharpened), lessThanOrEqualTo(minOf(img)), reason: 'ink should get darker or stay');
    expect(maxOf(sharpened), greaterThanOrEqualTo(maxOf(img)), reason: 'paper should get brighter or stay');
  });

  test('gray-world reduces color cast', () {
    final img = syntheticDocImage(warm: true);
    // measure average R-B difference before/after
    double castDiff(RgbaImage im) {
      var sum = 0.0;
      final n = im.width * im.height;
      for (var i = 0; i < n; i += 7) {
        final o = i * 4;
        sum += im.bytes[o] - im.bytes[o + 2];
      }
      return sum / (n / 7);
    }
    final before = castDiff(img);
    final balanced = ImageProcessor.grayWorldWhiteBalance(img);
    final after = castDiff(balanced);
    expect(after.abs(), lessThan(before.abs()),
        reason: 'cast before=$before after=$after');
  });

  test('smartEnhance gray whitens paper and keeps ink', () {
    final img = syntheticDocImage();
    final result = ImageProcessor.smartEnhance(img, const FilterParams(), color: false);
    expect(result.width, img.width);
    // paper pixels (e.g. corner) should be near-white
    final corner = result.bytes[(10 * result.width + 10) * 4];
    expect(corner, greaterThan(230), reason: 'paper should whiten, got $corner');
    // ink pixel should stay dark
    int darkest = 255;
    for (var i = 0; i < result.bytes.length; i += 4) {
      if (result.bytes[i] < darkest) darkest = result.bytes[i];
    }
    expect(darkest, lessThan(80), reason: 'ink must remain dark');
    // must be grayscale (R==G==B everywhere)
    for (var i = 0; i < result.bytes.length; i += 4) {
      expect(result.bytes[i], result.bytes[i + 1]);
      expect(result.bytes[i], result.bytes[i + 2]);
    }
  });

  test('smartEnhance color keeps saturation', () {
    final img = syntheticDocImage(warm: true);
    final result = ImageProcessor.smartEnhance(img, const FilterParams(), color: true);
    expect(result.width, img.width);
    // color mode: channels may differ (no forced gray)
    int maxChannelSpread = 0;
    for (var i = 0; i < result.bytes.length; i += 4) {
      final spread = result.bytes[i] - result.bytes[i + 2];
      if (spread.abs() > maxChannelSpread) maxChannelSpread = spread.abs();
    }
    expect(maxChannelSpread, greaterThan(0));
  });

  test('blackAndWhite binarizes with ink tone 24', () {
    final img = syntheticDocImage();
    final result = ImageProcessor.blackAndWhite(img, const FilterParams());
    var darkCount = 0, whiteCount = 0, midCount = 0, total = 0;
    for (var i = 0; i < result.bytes.length; i += 4) {
      final v = result.bytes[i];
      total++;
      if (v <= 60) {
        darkCount++;
      } else if (v >= 200) {
        whiteCount++;
      } else {
        midCount++; // sharpening ring along edges is expected
      }
    }
    expect(darkCount, greaterThan(0));
    expect(whiteCount, greaterThan(0));
    // body of image must be bimodal; only a small edge band may be transitional
    expect(midCount / total, lessThan(0.15), reason: 'too many mid-tones: $midCount/$total');
  });

  test('whitePaper lifts shadows', () {
    // build a dimmer paper image
    final img = syntheticDocImage();
    for (var i = 0; i < img.bytes.length; i += 4) {
      img.bytes[i] = (img.bytes[i] * 0.7).round();
      img.bytes[i + 1] = (img.bytes[i + 1] * 0.7).round();
      img.bytes[i + 2] = (img.bytes[i + 2] * 0.7).round();
    }
    final lifted = ImageProcessor.whitePaper(img, const FilterParams());
    var sumBefore = 0, sumAfter = 0;
    for (var i = 0; i < img.bytes.length; i += 4) {
      sumBefore += img.bytes[i];
      sumAfter += lifted.bytes[i];
    }
    expect(sumAfter, greaterThan(sumBefore), reason: 'lift should brighten paper');
  });

  test('filter dispatches by name and unknown falls back', () {
    final img = syntheticDocImage();
    final bw = ImageProcessor.filter(img, 'B&W');
    expect(bw.width, img.width);
    final same = ImageProcessor.filter(img, 'Nonexistent');
    expect(identical(same, img), isTrue, reason: 'unknown filter returns original');
  });

  test('enhanceDocument full pipeline runs', () {
    final img = syntheticDocImage();
    final result = ImageProcessor.enhanceDocument(img);
    expect(result.width, img.width);
    expect(result.height, img.height);
  });
}
