// Camera capture screen - Dart port of CameraScreen.kt (CamScanner-style UI)
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:async';

import 'package:camera/camera.dart' as cam;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'document_detector.dart';
import 'perspective.dart';

enum CaptureMode { single, multiple }

class CapturedPage {
  final RgbaImage image;
  final List<Point> corners; // may be empty if detection failed
  final DocumentDetectionResult? detection;
  CapturedPage({required this.image, this.corners = const [], this.detection});
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
  bool _capturing = false;
  int _capturedCount = 0;

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
    if (controller == null || _capturing) return;
    setState(() => _capturing = true);
    try {
      // 拍照前锁定一次对焦/曝光，让传感器有足够时间合焦，
      // 这对文档场景（大面积平面、低纹理）尤其重要
      try {
        await controller.setFocusMode(cam.FocusMode.auto);
        await Future<void>.delayed(const Duration(milliseconds: 350));
      } catch (_) {/* 设备不支持自动对焦则直接拍 */}
      final file = await controller.takePicture();
      // 立即恢复快门可用；后续解码为 native 快速调用，在主 isolate 同步完成。
      // 注意：不要在此方法内使用 Isolate.run——async 方法中的闭包会捕获
      // 方法上下文（含 CameraController/_Future），跨 isolate 发送必然报
      // "object is unsendable"。后台化需要 Isolate.spawn + 顶层 entrypoint。
      if (mounted) setState(() => _capturing = false);
      final bytes = await file.readAsBytes();
      final img = decodeCapture(bytes);
      final detection = DocumentEdgeDetector.detect(Uint8ListRgba(img.bytes, img.width, img.height));
      widget.onCaptured(CapturedPage(
        image: img,
        corners: detection.corners,
        detection: detection,
      ));
      _capturedCount++;
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        showErrorDialog(context, '拍摄失败', e);
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
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
          fit: BoxFit.cover,
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      widget.mode == CaptureMode.single ? 'Single' : 'Multiple ($_capturedCount)',
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
                    busy: _capturing,
                    onTap: _capture,
                  ),
                  const SizedBox(width: 72),
                ],
              ),
            ),
          ),
        ),
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
          child: busy
              ? const Padding(padding: EdgeInsets.all(18), child: CircularProgressIndicator(strokeWidth: 2))
              : null,
        ),
      ),
    );
  }
}

/// 顶层函数：在后台 isolate 中解码相机 JPEG 为 RGBA。
/// 必须是顶层/静态且只依赖参数（不捕获 State/Controller），
/// 否则 isolate spawn 会报 "object is unsendable"。
RgbaImage decodeCapture(Uint8List bytes) {
  final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
  if (mat.isEmpty) throw StateError('照片解码失败');
  final rgba = cv.cvtColor(mat, cv.COLOR_BGR2RGBA);
  final result = RgbaImage(Uint8List.fromList(rgba.data), rgba.cols, rgba.rows);
  mat.dispose();
  rgba.dispose();
  return result;
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
