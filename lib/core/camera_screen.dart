// Camera capture screen - Dart port of CameraScreen.kt (CamScanner-style UI)
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart' as cam;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'document_detector.dart';
import 'image_codec.dart';
import 'perspective.dart';

enum CaptureMode { single, multiple }

class CapturedPage {
  final RgbaImage image;
  final List<Point> corners; // may be empty if detection failed
  final DocumentDetectionResult? detection;
  final List<int> thumbBytes; // 缩略图 JPEG，后台 isolate 已生成
  CapturedPage({
    required this.image,
    this.corners = const [],
    this.detection,
    this.thumbBytes = const [],
  });
}

class CameraCaptureScreen extends StatefulWidget {
  final CaptureMode mode;
  final ValueChanged<CapturedPage> onCaptured;
  final VoidCallback onClose;

  const CameraCaptureScreen({
    super.key,
    required this.mode,
    required this.onCaptured,
    required this.onClose,
  });

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  cam.CameraController? _controller;
  List<cam.CameraDescription> _cameras = const [];
  bool _initializing = true;
  String? _error;
  bool _torchOn = false;
  bool _flash = false; // 按下快门瞬间的白屏提示
  bool _taking = false; // 仅锁住 takePicture，不阻塞 UI
  int _shots = 0; // 按下快门即 +1，给用户即时反馈

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await cam.availableCameras();
      final back = _cameras.firstWhere(
        (c) => c.lensDirection == cam.CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      // max：向系统请求传感器支持的最大分辨率，吃满硬件
      final controller = cam.CameraController(back, cam.ResolutionPreset.max, enableAudio: false);
      await controller.initialize();
      if (!mounted) return;
      // 开启连续自动对焦与自动曝光（硬件支持时），保证文档边缘始终清晰
      try {
        await controller.setFocusMode(cam.FocusMode.auto);
      } catch (_) {/* 设备不支持连续对焦则保持默认 */}
      try {
        await controller.setExposureMode(cam.ExposureMode.auto);
      } catch (_) {/* 不支持则保持默认 */}
      // 高分辨率下对焦速度慢，延长自动对焦稳定时间
      try {
        await controller.setFlashMode(cam.FlashMode.off);
      } catch (_) {/* 无闪光灯的设备 */}
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _initializing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _initializing = false;
      });
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || _taking) return; // 仅锁 takePicture，不弹转圈
    _taking = true;
    // 按下快门立刻给用户反馈：白屏闪一下 + 计数 +1，完全不等后台处理
    if (mounted) {
      setState(() {
        _shots++;
        _flash = true;
      });
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) setState(() => _flash = false);
      });
    }
    // 拍照前锁定一次对焦/曝光，让传感器有足够时间合焦
    try {
      try {
        await controller.setFocusMode(cam.FocusMode.auto);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (_) {/* 设备不支持自动对焦则直接拍 */}
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      _processAndDeliver(bytes); // 后台继续，不阻塞快门与下一次拍摄
    } catch (e) {
      if (mounted) showErrorDialog(context, '拍摄失败', e);
    } finally {
      _taking = false;
    }
  }

  /// 后台处理链路：isolate 解码 + 检测 + 缩略图，完成后回传给上层。
  /// 设计为“即发即忘”，不阻塞快门按钮。
  Future<void> _processAndDeliver(Uint8List bytes) async {
    try {
      // 解码 + 边缘检测是重 CPU 流水线（全分辨率 imdecode + 整套 OpenCV 检测），
      // 必须在后台 isolate 执行，否则主线程冻结、UI 卡死。
      // 只传 Uint8List（可发送），用顶层函数避免闭包捕获不可发送的上下文。
      final result = await processCaptureAsync(bytes);
      if (!mounted) return;
      final img = RgbaImage(result['rgba'] as Uint8List, result['width'] as int, result['height'] as int);
      final flat = (result['corners'] as List).cast<double>();
      final corners = [for (var i = 0; i < flat.length; i += 2) Point(flat[i], flat[i + 1])];
      final detection = DocumentDetectionResult(
        corners: corners,
        confidence: result['confidence'] as double,
        status: DocumentDetectionStatus.values[result['statusIndex'] as int],
        processingMs: result['processingMs'] as int,
        candidateCount: result['candidateCount'] as int,
        reason: result['reason'] as String?,
      );
      widget.onCaptured(CapturedPage(
        image: img,
        corners: detection.corners,
        detection: detection,
        thumbBytes: Uint8List.fromList(result['thumb'] as List<int>),
      ));
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) showErrorDialog(context, '处理失败', e);
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      final next = !_torchOn;
      await controller.setFlashMode(next ? cam.FlashMode.torch : cam.FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } catch (_) {/* 设备不支持常亮闪光则忽略 */}
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Camera unavailable: $_error',
                          style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton(onPressed: widget.onClose, child: const Text('Close')),
                    ],
                  ),
                )
              : _buildCameraUi(context),
    );
  }

  Widget _buildCameraUi(BuildContext context) {
    final controller = _controller!;
    // FittedBox(cover)：预览等比放大填满屏幕并裁掉溢出部分，
    // 既不拉伸变形也不留黑边（不要用 AspectRatio——竖屏会压成横条）
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          // contain：完整显示传感器取景框（不裁切放大），所见即所得，
          // 避免 cover 把预览放大裁切，导致实际照片四周还有更多内容。
          fit: BoxFit.contain,
          child: SizedBox(
            width: controller.value.previewSize!.height,
            height: controller.value.previewSize!.width,
            child: cam.CameraPreview(controller),
          ),
        ),
        // top bar
        SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white, size: 28),
                    onPressed: widget.onClose,
                  ),
                  IconButton(
                    icon: Icon(
                      _torchOn ? Icons.flash_on : Icons.flash_off,
                      color: _torchOn ? Colors.yellow : Colors.white,
                      size: 26,
                    ),
                    onPressed: _toggleTorch,
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      widget.mode == CaptureMode.single ? 'Single' : '已拍 $_shots 张',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
          ),
        ),
        // bottom controls
        Align(
          alignment: Alignment.bottomCenter,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 28),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(width: 72),
                  _ShutterButton(
                    busy: _taking,
                    onTap: _capture,
                  ),
                  const SizedBox(width: 72),
                ],
              ),
            ),
          ),
        ),
        // 按下快门瞬间的白屏闪一下的反馈，纯视觉、不阻塞
        if (_flash)
          Container(color: Colors.white),
      ],
    );
  }
}

class _ShutterButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onTap;

  const _ShutterButton({required this.busy, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        padding: const EdgeInsets.all(6),
        child: Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: busy ? Colors.white38 : Colors.white,
          ),
        ),
      ),
    );
  }
}

/// 后台 isolate 的入口：接收 (SendPort, 原始 JPEG 字节)，在独立 isolate
/// 中解码 + 边缘检测，把纯可发送结果通过 SendPort 回传。必须用顶层函数
/// 且通过参数传数据，绝对不能捕获任何 State/Controller（否则报 unsendable）。
void _processCaptureEntry(List<dynamic> args) {
  final port = args[0] as SendPort;
  final bytes = args[1] as Uint8List;
  final result = processCapture(bytes);
  port.send(result);
}

/// 在后台 isolate 中执行解码与边缘检测，主线程不阻塞（快门按下即可继续）。
/// 返回纯可发送数据，由调用方重建对象。
Future<Map<String, Object?>> processCaptureAsync(Uint8List bytes) async {
  final receive = ReceivePort();
  await Isolate.spawn(_processCaptureEntry, [receive.sendPort, bytes]);
  final result = await receive.first;
  receive.close();
  return result as Map<String, Object?>;
}

/// 后台 isolate 的业务逻辑：解码相机 JPEG -> RGBA，跑边缘检测，并生成 640 缩略图
/// 的 JPEG 字节。全部重活都在后台 isolate 完成，主线程只负责写文件。
/// 只依赖参数（不捕获 State/Controller），结果只含可跨 isolate 发送的数据。
Map<String, Object?> processCapture(Uint8List bytes) {
  final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (mat.isEmpty) throw StateError('照片解码失败');
  final rgba = cv.cvtColor(mat, cv.COLOR_BGR2RGBA);
  final width = rgba.cols, height = rgba.rows;
  final rgbaBytes = Uint8List.fromList(rgba.data);
  mat.dispose();
  rgba.dispose();
  final image = RgbaImage(rgbaBytes, width, height);
  final detection = DocumentEdgeDetector.detect(Uint8ListRgba(rgbaBytes, width, height));
  // 缩略图也在此生成（opencv imencode + 降采样），避免回主线程再做阻塞工作
  final thumbJpeg = encodeJpegBytes(thumbOf(image, 640));
  return {
    'rgba': rgbaBytes,
    'width': width,
    'height': height,
    'thumb': thumbJpeg,
    // 角点（归一化 0..1）扁平化为 [x0,y0,x1,y1,...]
    'corners': [for (final p in detection.corners) ...[p.x, p.y]],
    'confidence': detection.confidence,
    'statusIndex': detection.status.index,
    'processingMs': detection.processingMs,
    'candidateCount': detection.candidateCount,
    'reason': detection.reason,
  };
}

/// 通用错误弹窗：不自动消失（模态对话框），提供一键复制完整报错到剪贴板。
/// 所有面向用户的失败路径都应使用它，代替自动收回的 SnackBar，
/// 便于用户把报错完整反馈给开发者。
Future<void> showErrorDialog(BuildContext context, String title, Object error, [StackTrace? stack]) {
  final text = '$title\n$error${stack == null ? '' : '\n$stack'}';
  return showDialog<void>(
    context: context,
    barrierDismissible: false, // 点击遮罩不关闭，必须显式操作
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: SelectableText(
          text,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (ctx.mounted) {
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('报错已复制到剪贴板'), duration: Duration(seconds: 2)),
              );
            }
          },
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('复制报错'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
