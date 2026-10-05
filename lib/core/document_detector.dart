// ClearScan document edge detection - Dart port of DocumentEdgeDetector.kt
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:opencv_dart/opencv_dart.dart' as cv;

enum DocumentDetectionStatus { idle, detecting, detected, lowConfidence, failed }

enum PageDetectionProfile { document, worksheet, book, idCard }

class Point {
  final double x, y;
  const Point(this.x, this.y);
}

class DocumentDetectionResult {
  final List<Point> corners; // normalized 0..1
  final double confidence;
  final DocumentDetectionStatus status;
  final int processingMs;
  final int candidateCount;
  final String? reason;

  DocumentDetectionResult({
    required this.corners,
    required this.confidence,
    required this.status,
    required this.processingMs,
    this.candidateCount = 0,
    this.reason,
  });
}

class Uint8ListRgba {
  final Uint8List bytes;
  final int width;
  final int height;
  const Uint8ListRgba(this.bytes, this.width, this.height);
}

class _QuadCandidate {
  final List<Point> points;
  final double score;
  _QuadCandidate(this.points, this.score);
}

class DocumentEdgeDetector {
  static const double _analysisLongSide = 1280.0;
  static const double _minAreaRatio = 0.06;
  static const double _minConfidence = 0.50;
  static const int _cv16s = 3; // CV_16S

  static DocumentDetectionResult detect(
    Uint8ListRgba rgba, {
    PageDetectionProfile profile = PageDetectionProfile.document,
  }) {
    final started = DateTime.now().millisecondsSinceEpoch;
    if (rgba.width < 64 || rgba.height < 64) {
      return _failed(started, 'Image is too small');
    }

    final source = cv.Mat.fromList(rgba.height, rgba.width, cv.MatType.CV_8UC4, rgba.bytes);
    cv.Mat? scaled, rgb, gray, blurred, edges, closed, equalized, adaptive, gradX, gradY, absX, absY, gradient, kernel;
    final channels = <cv.Mat>[];
    final candidates = <_QuadCandidate>[];

    try {
      final longest = math.max(source.cols, source.rows).toDouble();
      final scale = math.min(1.0, _analysisLongSide / longest);
      if (scale < 1.0) {
        scaled = cv.resize(source, ((source.cols * scale).toInt(), (source.rows * scale).toInt()),
            interpolation: cv.INTER_AREA);
      } else {
        scaled = source.clone();
      }
      rgb = cv.cvtColor(scaled, cv.COLOR_RGBA2RGB);
      gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY);
      equalized = cv.Mat.empty();
      final clahe = cv.CLAHE.create(2.2, (8, 8));
      clahe.apply(gray, dst: equalized);
      clahe.dispose();
      final planes = cv.split(rgb);
      for (final p in planes) {
        channels.add(p);
      }

      kernel = cv.getStructuringElement(cv.MORPH_RECT, (7, 7));
      closed = cv.Mat.empty();

      void collectCandidates(cv.Mat mask) {
        final sc = scaled!;
        cv.morphologyEx(mask, cv.MORPH_CLOSE, kernel!, dst: closed, iterations: 2);
        final (contours, _) = cv.findContours(mask, cv.RETR_LIST, cv.CHAIN_APPROX_SIMPLE);
        final sorted = contours.toList()
          ..sort((a, b) => cv.contourArea(b).abs().compareTo(cv.contourArea(a).abs()));
        for (final contour in sorted.take(80)) {
          final cand = _candidateFrom(contour, mask, sc.cols, sc.rows, profile);
          if (cand != null) candidates.add(cand);
        }
      }

      blurred = cv.Mat.empty();
      edges = cv.Mat.empty();
      for (final plane in [gray, equalized, ...channels]) {
        cv.gaussianBlur(plane, (5, 5), 0, dst: blurred);
        final luminance = _averageLuminance(blurred);
        final low = (luminance * .45).clamp(20.0, 65.0);
        final high = math.max(low * 2.2, math.min(luminance * 1.15, 180.0));
        cv.canny(blurred, low, high, edges: edges, apertureSize: 3, l2gradient: true);
        collectCandidates(edges);
      }
      adaptive = cv.adaptiveThreshold(
          equalized, 255, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY, 31, 9.0);
      collectCandidates(adaptive);
      cv.bitwiseNOT(adaptive, dst: adaptive);
      collectCandidates(adaptive);
      gradX = cv.scharr(equalized, _cv16s, 1, 0);
      gradY = cv.scharr(equalized, _cv16s, 0, 1);
      absX = cv.convertScaleAbs(gradX);
      absY = cv.convertScaleAbs(gradY);
      gradient = cv.addWeighted(absX, .5, absY, .5, 0);
      final (_, otsu) = cv.threshold(gradient, 0, 255, cv.THRESH_BINARY | cv.THRESH_OTSU);
      gradient.dispose();
      gradient = otsu;
      collectCandidates(gradient);

      if (candidates.isEmpty) {
        return DocumentDetectionResult(
          corners: const [],
          confidence: 0,
          status: DocumentDetectionStatus.failed,
          processingMs: _elapsed(started),
          reason: 'No document quadrilateral found',
        );
      }
      var best = candidates[0];
      for (final c in candidates) {
        if (c.score > best.score) best = c;
      }
      final sc0 = scaled;
      final refined = _refineCorners(equalized, best.points)
          .map((p) => Point((p.x / sc0.cols).clamp(0.0, 1.0), (p.y / sc0.rows).clamp(0.0, 1.0)))
          .toList();
      final status = best.score >= _minConfidence
          ? DocumentDetectionStatus.detected
          : DocumentDetectionStatus.lowConfidence;
      return DocumentDetectionResult(
        corners: refined,
        confidence: best.score,
        status: status,
        processingMs: _elapsed(started),
        candidateCount: candidates.length,
        reason: status == DocumentDetectionStatus.lowConfidence ? 'Document boundary confidence is low' : null,
      );
    } catch (error) {
      return DocumentDetectionResult(
        corners: const [],
        confidence: 0,
        status: DocumentDetectionStatus.failed,
        processingMs: _elapsed(started),
        reason: error.toString(),
      );
    } finally {
      for (final m in channels) {
        m.dispose();
      }
      source.dispose();
      scaled?.dispose();
      rgb?.dispose();
      gray?.dispose();
      blurred?.dispose();
      edges?.dispose();
      closed?.dispose();
      equalized?.dispose();
      adaptive?.dispose();
      gradX?.dispose();
      gradY?.dispose();
      absX?.dispose();
      absY?.dispose();
      gradient?.dispose();
      kernel?.dispose();
    }
  }

  static _QuadCandidate? _candidateFrom(
      cv.VecPoint contour, cv.Mat edgeMask, int width, int height, PageDetectionProfile profile) {
    final area = cv.contourArea(contour).abs();
    final imageArea = width.toDouble() * height.toDouble();
    final areaRatio = area / imageArea;
    if (areaRatio < _minAreaRatio || areaRatio > 0.985) return null;

    final curve = cv.VecPoint2f.fromList(
        contour.map((p) => cv.Point2f(p.x.toDouble(), p.y.toDouble())).toList());
    try {
      final perimeter = cv.arcLength2f(curve, true);
      _QuadCandidate? best;
      for (final epsilon in const [.012, .017, .022, .030, .040]) {
        final polygon = cv.approxPolyDP2f(curve, perimeter * epsilon, true);
        try {
          final pts = polygon.map((p) => Point(p.x.toDouble(), p.y.toDouble())).toList();
          final cand = _scoreQuad(pts, area, imageArea, edgeMask, width, height, profile);
          if (cand != null && (best == null || cand.score > best.score)) best = cand;
        } finally {
          polygon.dispose();
        }
      }
      return best;
    } finally {
      curve.dispose();
    }
  }

  static _QuadCandidate? _scoreQuad(List<Point> points, double contourArea, double imageArea,
      cv.Mat edgeMask, int width, int height, PageDetectionProfile profile) {
    if (points.length != 4) return null;
    final ordered = _orderCorners(points);
    if (!_isConvex(ordered)) return null;
    final quadArea = _boundingQuadArea(ordered);
    final areaRatio = quadArea / imageArea;
    if (areaRatio < _minAreaRatio || areaRatio > .985) return null;
    final angleScore = _rightAngleScore(ordered);
    if (angleScore < .30) return null;
    final rectangularity = (contourArea / quadArea).clamp(0.0, 1.0);
    final centerX = ordered.fold<double>(0, (s, p) => s + p.x) / 4.0;
    final centerY = ordered.fold<double>(0, (s, p) => s + p.y) / 4.0;
    final cdx = centerX / width - .5;
    final cdy = centerY / height - .5;
    final centerDistance = math.sqrt(cdx * cdx + cdy * cdy) / .707;
    final centerScore = (1.0 - centerDistance).clamp(0.0, 1.0);
    final borderRaw = ordered
            .map((p) => math.min(math.min(p.x / width, 1.0 - p.x / width), math.min(p.y / height, 1.0 - p.y / height)))
            .fold<double>(0, (s, v) => s + v) /
        4.0;
    final borderScore = (borderRaw / .025).clamp(0.0, 1.0);
    final areaScore = ((areaRatio - _minAreaRatio) / (.72 - _minAreaRatio)).clamp(0.0, 1.0);
    final edgeScore = _edgeSupport(edgeMask, ordered);
    final topWidth = _dist(ordered[0], ordered[1]);
    final bottomWidth = _dist(ordered[3], ordered[2]);
    final leftHeight = _dist(ordered[0], ordered[3]);
    final rightHeight = _dist(ordered[1], ordered[2]);
    final ratio = math.max(topWidth, bottomWidth) / math.max(1.0, math.max(leftHeight, rightHeight));
    final double profileScore;
    switch (profile) {
      case PageDetectionProfile.idCard:
        profileScore = (1.0 - (ratio - 1.586).abs() / 1.2).clamp(0.0, 1.0);
      case PageDetectionProfile.book:
        profileScore = (1.0 - (ratio - .72).abs() / 1.4).clamp(0.0, 1.0);
      case PageDetectionProfile.worksheet:
        profileScore = (1.0 - (ratio - .707).abs() / 1.2).clamp(0.0, 1.0);
      case PageDetectionProfile.document:
        profileScore = (1.0 - math.min((ratio - .707).abs(), (ratio - 1.414).abs()) / 1.8).clamp(.55, 1.0);
    }
    final score = (areaScore * .29 + angleScore * .18 + rectangularity * .10 + centerScore * .09 +
            borderScore * .03 + edgeScore * .22 + profileScore * .09)
        .clamp(0.0, 1.0);
    return _QuadCandidate(ordered, score);
  }

  static double _averageLuminance(cv.Mat gray) {
    final m = cv.mean(gray);
    return m.val1.clamp(1.0, 254.0);
  }

  static List<Point> _refineCorners(cv.Mat gray, List<Point> points) {
    var corners = cv.VecPoint2f.fromList(
        points.map((p) => cv.Point2f(p.x, p.y)).toList());
    try {
      corners = cv.cornerSubPix(gray, corners, (7, 7), (-1, -1), (3, 30, .05));
      final refined = corners.map((p) => Point(p.x.toDouble(), p.y.toDouble())).toList();
      if (refined.length != 4) return points;
      return _orderCorners(refined);
    } catch (_) {
      // cornerSubPix 只是亚像素级精修（可选优化），失败时返回原始角点，
      // 检测主流程不受影响——这不是功能性降级
      return points;
    } finally {
      corners.dispose();
    }
  }

  static double _edgeSupport(cv.Mat mask, List<Point> points) {
    var hits = 0;
    var total = 0;
    for (var index = 0; index < points.length; index++) {
      final from = points[index];
      final to = points[(index + 1) % points.length];
      for (var step = 0; step < 40; step++) {
        final t = step / 39.0;
        final x = (from.x + (to.x - from.x) * t).toInt().clamp(1, mask.cols - 2);
        final y = (from.y + (to.y - from.y) * t).toInt().clamp(1, mask.rows - 2);
        total++;
        var found = false;
        for (var dy = -1; dy <= 1 && !found; dy++) {
          for (var dx = -1; dx <= 1 && !found; dx++) {
            if (mask.atU8(y + dy, i1: x + dx) > 0) {
              found = true;
            }
          }
        }
        if (found) hits++;
      }
    }
    return total == 0 ? 0.0 : hits / total;
  }

  static List<Point> orderNormalizedCorners(List<Point> points) {
    assert(points.length == 4);
    return _orderCorners(points);
  }

  static List<Point> _orderCorners(List<Point> points) {
    var topLeft = points[0], topRight = points[0], bottomRight = points[0], bottomLeft = points[0];
    for (final p in points) {
      if (p.x + p.y < topLeft.x + topLeft.y) topLeft = p;
      if (p.x + p.y > bottomRight.x + bottomRight.y) bottomRight = p;
      if (p.x - p.y > topRight.x - topRight.y) topRight = p;
      if (p.x - p.y < bottomLeft.x - bottomLeft.y) bottomLeft = p;
    }
    return [topLeft, topRight, bottomRight, bottomLeft];
  }

  static bool _isConvex(List<Point> pts) {
    var signs = 0;
    for (var i = 0; i < 4; i++) {
      final prev = pts[(i + 3) % 4], cur = pts[i], next = pts[(i + 1) % 4];
      final cross = (cur.x - prev.x) * (next.y - cur.y) - (cur.y - prev.y) * (next.x - cur.x);
      if (cross != 0) {
        final s = cross > 0 ? 1 : -1;
        if (signs == 0) signs = s;
        if (signs != s) return false;
      }
    }
    return true;
  }

  static double _rightAngleScore(List<Point> points) {
    var sum = 0.0;
    for (var index = 0; index < 4; index++) {
      final previous = points[(index + 3) % 4];
      final current = points[index];
      final next = points[(index + 1) % 4];
      final ax = previous.x - current.x;
      final ay = previous.y - current.y;
      final bx = next.x - current.x;
      final by = next.y - current.y;
      final denominator = math.sqrt(ax * ax + ay * ay) * math.sqrt(bx * bx + by * by);
      if (denominator < 1.0) continue;
      final cosv = ((ax * bx + ay * by) / denominator).clamp(-1.0, 1.0);
      final angle = math.acos(cosv) * 180 / math.pi;
      sum += (1.0 - (angle - 90.0).abs() / 70.0).clamp(0.0, 1.0);
    }
    return sum / 4.0;
  }

  static double _boundingQuadArea(List<Point> points) {
    var sum = 0.0;
    for (var index = 0; index < points.length; index++) {
      final next = points[(index + 1) % points.length];
      sum += points[index].x * next.y - next.x * points[index].y;
    }
    return math.max(1.0, sum.abs() / 2.0);
  }

  static double _dist(Point a, Point b) =>
      math.sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y));

  static DocumentDetectionResult _failed(int started, String reason) => DocumentDetectionResult(
        corners: const [],
        confidence: 0,
        status: DocumentDetectionStatus.failed,
        processingMs: _elapsed(started),
        reason: reason,
      );

  static int _elapsed(int started) => DateTime.now().millisecondsSinceEpoch - started;
}
