// Camera capture screen - Dart port of CameraScreen.kt (CamScanner-style UI)
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart' as cam;
import 'package:flutter/material.dart';
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
      // 立即恢复快门可用，解码/检测在后台 isolate 进行，不阻塞连拍
      if (mounted) setState(() => _capturing = false);
      // 后台 isolate：先在主 isolate 读字节，再传给顶层静态函数处理。
      // 闭包绝不能捕获 State/controller（native 资源不可跨 isolate 发送）
      final bytes = await file.readAsBytes();
      final img = await Isolate.run(() => decodeCapture(bytes));
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('拍摄失败: $e')));
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
