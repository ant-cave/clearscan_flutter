// Dart port of ImageProcessor (filters) from ClearScan MainActivity.kt
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'perspective.dart';

/// User-tunable parameters for the OpenCV-accelerated filters. Defaults match the original look.
class FilterParams {
  /// Adaptive-threshold bias for B&W / Ink: lower picks up fainter strokes, higher keeps them thin and clean (2..30).
  final double threshold;

  /// Multiplier applied to each filter's sharpen amount (0..1.6).
  final double sharpenScale;

  /// White Paper lift gamma: lower lifts shadows more (0.72..1.0).
  final double paperLift;

  /// Median denoise kernel before B&W binarization: 1 = off, 3 = standard, 5 = aggressive (odd only).
  final int denoise;

  /// Strength of the division-normalization "smart" filters (0 = original, 1 = full normalization).
  final double smartStrength;

  const FilterParams({
    this.threshold = 12,
    this.sharpenScale = 1,
    this.paperLift = .88,
    this.denoise = 3,
    this.smartStrength = 1,
  });
}

class ImageProcessor {
  ///gray-world white balance + slight contrast/brightness + sharpen. Matches enhanceDocument().
  static RgbaImage enhanceDocument(RgbaImage bitmap) {
    final balanced = grayWorldWhiteBalance(bitmap);
    final adjusted = adjust(balanced, .025, 1.14, 1.0) ?? balanced;
    return sharpen(adjusted, amount: .72);
  }

  static RgbaImage filter(RgbaImage? bitmap, String name, [FilterParams params = const FilterParams()]) {
    if (bitmap == null) return RgbaImage.blank(1, 1);
    switch (name) {
      case 'Smart Gray':
        return smartEnhance(bitmap, params, color: false);
      case 'Magic Color':
        return smartEnhance(bitmap, params, color: true);
      case 'B&W':
        return blackAndWhite(bitmap, params);
      case 'Ink':
        return sharpen(blackAndWhite(bitmap, params), amount: .35 * params.sharpenScale);
      case 'White Paper':
        return whitePaper(bitmap, params);
      // Unknown names (e.g. legacy pages saved with removed presets) fall back to the original.
      default:
        return bitmap;
    }
  }

  // ---------- adjust (brightness/contrast/saturation via color matrix) ----------

  static RgbaImage? adjust(RgbaImage? bitmap, double brightness, double contrast, double saturation) {
    if (bitmap == null) return null;
    final scale = contrast;
    final translate = (-0.5 * scale + 0.5 + brightness) * 255;
    // Combined matrix: saturation then contrast (matches ColorMatrix.postConcat order).
    // Saturation matrix (luminance weights): R' = (1-s)*lumR*sat + s etc.
    const lr = 0.213, lg = 0.715, lb = 0.072;
    final s = saturation;
    // saturation matrix rows
    final m = List<double>.filled(20, 0);
    m[0] = lr * (1 - s) + s;
    m[1] = lg * (1 - s);
    m[2] = lb * (1 - s);
    m[5] = lr * (1 - s);
    m[6] = lg * (1 - s) + s;
    m[7] = lb * (1 - s);
    m[10] = lr * (1 - s);
    m[11] = lg * (1 - s);
    m[12] = lb * (1 - s) + s;
    m[18] = 1;
    // contrast+brightness matrix
    final c = List<double>.filled(20, 0);
    c[0] = scale; c[4] = translate;
    c[6] = scale; c[9] = translate;
    c[12] = scale; c[14] = translate;
    c[18] = 1;
    // postConcat: result = contrast * saturation (row-vector convention); we apply saturation first, then contrast.
    (int, int, int) apply(double r, double g, double b) {
      final sr = m[0] * r + m[1] * g + m[2] * b;
      final sg = m[5] * r + m[6] * g + m[7] * b;
      final sb = m[10] * r + m[11] * g + m[12] * b;
      final cr = (c[0] * sr + c[4]).round().clamp(0, 255);
      final cg = (c[6] * sg + c[9]).round().clamp(0, 255);
      final cb = (c[12] * sb + c[14]).round().clamp(0, 255);
      return (cr, cg, cb);
    }

    final n = bitmap.width * bitmap.height;
    final out = Uint8List(n * 4);
    final src = bitmap.bytes;
    for (var i = 0; i < n; i++) {
      final o = i * 4;
      final (cr, cg, cb) = apply(src[o].toDouble(), src[o + 1].toDouble(), src[o + 2].toDouble());
      out[o] = cr;
      out[o + 1] = cg;
      out[o + 2] = cb;
      out[o + 3] = 255;
    }
    return RgbaImage(out, bitmap.width, bitmap.height);
  }

  // ---------- sharpen (unsharp mask) ----------

  /// Unsharp mask, pure Dart with a separable box blur (two passes) as the
  /// low-pass. OpenCV path dropped: the addWeighted result Mat was finalizer-prone
  /// in the VM tester; a box blur is visually equivalent here.
  static RgbaImage sharpen(RgbaImage bitmap, {double amount = 1}) {
    if (amount <= 0) return bitmap;
    final w = bitmap.width, h = bitmap.height;
    final src = bitmap.bytes;
    final radius = (amount * 2).round().clamp(1, 4);
    final tmp = Uint8List(w * h * 4);
    final blur = Uint8List(w * h * 4);
    final div = radius * 2 + 1;
    // horizontal pass
    for (var y = 0; y < h; y++) {
      final row = y * w * 4;
      for (var c = 0; c < 4; c++) {
        var sum = 0;
        for (var dx = -radius; dx <= radius; dx++) {
          sum += src[row + dx.clamp(0, w - 1) * 4 + c];
        }
        tmp[row + c] = sum ~/ div;
        for (var x = 1; x < w; x++) {
          sum += src[row + math.min(x + radius, w - 1) * 4 + c] -
              src[row + math.max(x - radius - 1, 0) * 4 + c];
          tmp[row + x * 4 + c] = sum ~/ div;
        }
      }
    }
    // vertical pass
    for (var x = 0; x < w; x++) {
      for (var c = 0; c < 4; c++) {
        var sum = 0;
        for (var dy = -radius; dy <= radius; dy++) {
          sum += tmp[dy.clamp(0, h - 1) * w * 4 + x * 4 + c];
        }
        blur[x * 4 + c] = sum ~/ div;
        for (var y = 1; y < h; y++) {
          sum += tmp[math.min(y + radius, h - 1) * w * 4 + x * 4 + c] -
              tmp[math.max(y - radius - 1, 0) * w * 4 + x * 4 + c];
          blur[y * w * 4 + x * 4 + c] = sum ~/ div;
        }
      }
    }
    final out = Uint8List(w * h * 4);
    for (var i = 0; i < out.length; i += 4) {
      for (var c = 0; c < 3; c++) {
        out[i + c] = (src[i + c] + amount * (src[i + c] - blur[i + c])).round().clamp(0, 255);
      }
      out[i + 3] = 255;
    }
    return RgbaImage(out, w, h);
  }

  // ---------- gray-world white balance ----------

  /// Gray-world white balance. Pure Dart: the mask/mean statistics are trivially
  /// vectorizable here and the OpenCV path (cv.split + VecMat finalizers) proved
  /// double-free prone in the VM test environment.
  static RgbaImage grayWorldWhiteBalance(RgbaImage bitmap) => grayWorldFallback(bitmap);

  static RgbaImage grayWorldFallback(RgbaImage bitmap) {
    // Pure-dart gray-world over bright, low-saturation pixels.
    final n = bitmap.width * bitmap.height;
    final src = bitmap.bytes;
    var count = 0;
    final sums = List<int>.filled(3, 0);
    for (var i = 0; i < n; i++) {
      final o = i * 4;
      final r = src[o], g = src[o + 1], b = src[o + 2];
      final mx = math.max(r, math.max(g, b));
      final mn = math.min(r, math.min(g, b));
      if (mx - mn <= 80 && mx >= 48) {
        sums[0] += r; sums[1] += g; sums[2] += b; count++;
      }
    }
    if (count < 64) return bitmap;
    final avg = sums.map((s) => s / count).toList();
    final gray = (avg[0] + avg[1] + avg[2]) / 3;
    double gain(double average) => (gray / average).clamp(.82, 1.18);
    final gains = [gain(avg[0]), gain(avg[1]), gain(avg[2])];
    final out = Uint8List(n * 4);
    for (var i = 0; i < n; i++) {
      final o = i * 4;
      out[o] = (src[o] * gains[0]).round().clamp(0, 255);
      out[o + 1] = (src[o + 1] * gains[1]).round().clamp(0, 255);
      out[o + 2] = (src[o + 2] * gains[2]).round().clamp(0, 255);
      out[o + 3] = 255;
    }
    return RgbaImage(out, bitmap.width, bitmap.height);
  }

  // ---------- smart enhance (Smart Gray / Magic Color) ----------

  static RgbaImage smartEnhance(RgbaImage bitmap, FilterParams params, {required bool color}) {
    final width = bitmap.width;
    final height = bitmap.height;
    final n = width * height;
    final strength = params.smartStrength;

    // Downscale+upscale approximates the large-kernel Gaussian background estimate.
    final factor = 16;
    final sw = math.max(1, width ~/ factor);
    final sh = math.max(1, height ~/ factor);
    final src = cv.Mat.fromList(height, width, cv.MatType.CV_8UC4, bitmap.bytes);
    RgbaImage result;
    try {
      final small = cv.resize(src, (sw, sh), interpolation: cv.INTER_AREA);
      final backgroundMat = cv.resize(small, (width, height), interpolation: cv.INTER_LINEAR);
      small.dispose();
      // 深拷贝背景数据，避免 Mat 释放后读取悬空内存
      final bg = Uint8List.fromList(backgroundMat.data);
      backgroundMat.dispose();

      final resultBytes = Uint8List(n * 4);
      final grayHistogram = List<int>.filled(256, 0);
      final srcBytes = bitmap.bytes;

      int divideChannel(int value, int bgValue) {
        final denominator = bgValue * strength + 255 * (1 - strength);
        return denominator < 1 ? value : (value * 255 / denominator).round().clamp(0, 255);
      }

      for (var i = 0; i < n; i++) {
        final o = i * 4;
        final bo = i * 4;
        final r = divideChannel(srcBytes[o], bg[bo]);
        final g = divideChannel(srcBytes[o + 1], bg[bo + 1]);
        final b = divideChannel(srcBytes[o + 2], bg[bo + 2]);
        if (color) {
          resultBytes[o] = r; resultBytes[o + 1] = g; resultBytes[o + 2] = b;
        } else {
          final gray = (r * 0.299 + g * 0.587 + b * 0.114).round().clamp(0, 255);
          grayHistogram[gray]++;
          resultBytes[o] = gray; resultBytes[o + 1] = gray; resultBytes[o + 2] = gray;
        }
        resultBytes[o + 3] = 255;
      }

      if (!color) {
        // Auto black/white stretch from the gray histogram (0.4% / 99.6% percentiles).
        var low = 0, high = 255;
        var cumulative = 0;
        final lowTarget = n * .004;
        final highTarget = n * .996;
        for (var index = 0; index < 256; index++) {
          cumulative += grayHistogram[index];
          if (cumulative >= lowTarget) { low = index; break; }
        }
        cumulative = 0;
        for (var index = 0; index < 256; index++) {
          cumulative += grayHistogram[index];
          if (cumulative >= highTarget) { high = index; break; }
        }
        if (high - low >= 24) {
          final span = high - low;
          for (var i = 0; i < n; i++) {
            final o = i * 4;
            final gray = ((resultBytes[o] - low) * 255 ~/ span).clamp(0, 255);
            resultBytes[o] = gray; resultBytes[o + 1] = gray; resultBytes[o + 2] = gray;
          }
        }
        result = RgbaImage(resultBytes, width, height);
        return sharpen(result, amount: .5 * params.sharpenScale);
      }
      result = RgbaImage(resultBytes, width, height);
      final adjusted = adjust(result, .02, 1.03, 1.22) ?? result;
      return sharpen(adjusted, amount: .35 * params.sharpenScale);
    } finally {
      src.dispose();
    }
  }

  // ---------- white paper ----------

  static RgbaImage whitePaper(RgbaImage bitmap, FilterParams params) {
    final balanced = grayWorldWhiteBalance(bitmap);
    return _whitePaperLift(balanced, params.paperLift);
  }

  /// Levels lift ((c-14)/224)^gamma applied through a 256-entry LUT.
  static RgbaImage _whitePaperLift(RgbaImage bitmap, double gamma) {
    final lut = List<int>.filled(256, 0);
    for (var index = 0; index < 256; index++) {
      final normalized = ((index - 14) / 224).clamp(0.0, 1.0);
      lut[index] = (255 * math.pow(normalized, gamma)).round().clamp(0, 255);
    }
    final n = bitmap.width * bitmap.height;
    final out = Uint8List(n * 4);
    final src = bitmap.bytes;
    for (var i = 0; i < n; i++) {
      final o = i * 4;
      out[o] = lut[src[o]];
      out[o + 1] = lut[src[o + 1]];
      out[o + 2] = lut[src[o + 2]];
      out[o + 3] = 255;
    }
    return RgbaImage(out, bitmap.width, bitmap.height);
  }

  // ---------- black & white ----------

  static RgbaImage blackAndWhite(RgbaImage bitmap, FilterParams params) {
    final balanced = grayWorldWhiteBalance(bitmap);
    // 不再静默降级到 fallback：OpenCV 自适应阈值失败应当场报错，
    // 否则用户会看到"滤镜已应用"但效果与预期完全不同
    final bw = _blackAndWhiteAdaptive(balanced, params.threshold, params.denoise);
    return sharpen(bw, amount: .6 * params.sharpenScale);
  }

  /// Local adaptive threshold (Gaussian) so uneven lighting doesn't collapse into blotches.
  /// Ink keeps the original near-black tone of 24.
  static RgbaImage _blackAndWhiteAdaptive(RgbaImage bitmap, double bias, int denoiseKernel) {
    final src = cv.Mat.fromList(bitmap.height, bitmap.width, cv.MatType.CV_8UC4, bitmap.bytes);
    try {
      var gray = cv.cvtColor(src, cv.COLOR_RGBA2GRAY);
      cv.Mat? blurred;
      // Kernel 1 is a no-op, so denoising can be turned off entirely.
      if (denoiseKernel >= 3) {
        final k = denoiseKernel % 2 == 0 ? denoiseKernel + 1 : denoiseKernel;
        blurred = cv.medianBlur(gray, k);
        gray.dispose();
        gray = blurred;
      }
      var requested = (math.min(gray.cols, gray.rows) ~/ 16).clamp(25, 101);
      if (requested % 2 == 0) requested += 1;
      final binary = cv.adaptiveThreshold(
          gray, 255, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, requested, bias);
      // Map 0 -> 24 (ink) and 255 -> 255 (paper) to preserve the original tone.
      final remapped = cv.convertScaleAbs(binary, alpha: 231.0 / 255.0, beta: 24.0);
      final h = bitmap.height, w = bitmap.width;
      // 深拷贝后再释放 Mat，避免读到悬空 native 内存（真机上会输出黑图）
      final remappedBytes = Uint8List.fromList(remapped.data);
      final out = Uint8List(h * w * 4);
      final oSize = w * h;
      for (var i = 0; i < oSize; i++) {
        final v = remappedBytes[i];
        final o = i * 4;
        out[o] = v; out[o + 1] = v; out[o + 2] = v; out[o + 3] = 255;
      }
      gray.dispose(); binary.dispose(); remapped.dispose();
      return RgbaImage(out, w, h);
    } finally {
      src.dispose();
    }
  }
}

