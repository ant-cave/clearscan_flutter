// Camera capture screen - Dart port of CameraScreen.kt (CamScanner-style UI)
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:async';
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

  Uint8List? _lastFrameBytes;
  final int _lastFrameW = 0, _lastFrameH = 0;

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
      final controller = cam.CameraController(back, cam.ResolutionPreset.high, enableAudio: false);
      await controller.initialize();
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
      final file = await controller.takePicture();
      final bytes = await file.readAsBytes();
      // decode via opencv imdecode
      final mat = cv.imdecode(bytes, cv.IMREAD_COLOR);
      RgbaImage img;
      if (mat.isEmpty) {
        // fallback: use last preview frame
        if (_lastFrameBytes == null) return;
        img = RgbaImage(_lastFrameBytes!, _lastFrameW, _lastFrameH);
      } else {
        final rgba = cv.cvtColor(mat, cv.COLOR_BGR2RGBA);
        img = RgbaImage(Uint8List.fromList(rgba.data), rgba.cols, rgba.rows);
        mat.dispose();
        rgba.dispose();
      }
      final detection = DocumentEdgeDetector.detect(Uint8ListRgba(img.bytes, img.width, img.height));
      widget.onCaptured(CapturedPage(
        image: img,
        corners: detection.corners,
        detection: detection,
      ));
      _capturedCount++;
      if (widget.mode == CaptureMode.single && mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Capture failed: $e')));
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
    return Stack(
      fit: StackFit.expand,
      children: [
        cam.CameraPreview(controller),
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
