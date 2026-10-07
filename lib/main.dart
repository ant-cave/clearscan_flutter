// ClearScan Flutter - main app: home list, capture flow, editor, export
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'core/camera_screen.dart';
import 'core/document_detector.dart';
import 'core/document_store.dart';
import 'core/image_codec.dart';
import 'package:image_picker/image_picker.dart';
import 'core/image_processor.dart';
import 'core/perspective.dart';

void main() {
  runApp(const ClearScanApp());
}

/// 导出文件名中的非法字符替换。
String safeFileName(String name) => name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

/// 导出目录：优先应用外部存储（Android/data/<包>/files/export，用户可通过
/// 文件管理器或 USB 访问），不可用时回退到应用内部目录。导出到系统公共
/// Pictures/Documents 需要 MediaStore 原生支持，暂未启用。
Future<Directory> exportDirectory() async {
  final dirs = await getExternalStorageDirectories();
  if (dirs != null && dirs.isNotEmpty) {
    final dir = Directory(p.join(dirs.first.path, 'export'));
    await dir.create(recursive: true);
    return dir;
  }
  final fallback = Directory(p.join((await DocumentStore.documentsRoot()).parent.path, 'Download'));
  await fallback.create(recursive: true);
  return fallback;
}

class ClearScanApp extends StatelessWidget {
  const ClearScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClearScan',
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2962FF),
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: const Color(0xFF2962FF),
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomeScreen(),
    );
  }
}

// ------------------------------ Home ------------------------------

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<DocumentMeta> _docs = [];
  bool _loading = true;
  CaptureMode _mode = CaptureMode.multiple;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final docs = await DocumentStore.listDocuments();
    if (!mounted) return;
    setState(() {
      _docs = docs;
      _loading = false;
    });
  }

  Future<void> _startCapture() async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CaptureFlowScreen(mode: _mode),
      ),
    );
    if (saved == true) _refresh();
  }

  Future<void> _importFromGallery() async {
    final picker = ImagePicker();
    final picked = await picker.pickMultiImage(limit: 10);
    if (picked.isEmpty) return;
    if (!mounted) return;
    // route through the same draft->crop->save flow with preloaded images
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => GalleryImportScreen(xFiles: picked, mode: _mode),
      ),
    );
    if (saved == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ClearScan'),
        actions: [
          SegmentedButton<CaptureMode>(
            segments: const [
              ButtonSegment(value: CaptureMode.single, label: Text('单张'), icon: Icon(Icons.crop_free)),
              ButtonSegment(value: CaptureMode.multiple, label: Text('多张'), icon: Icon(Icons.photo_library)),
            ],
            selected: {_mode},
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _docs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.document_scanner, size: 72, color: Theme.of(context).colorScheme.primary.withValues(alpha: .4)),
                      const SizedBox(height: 12),
                      Text('还没有文档', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text('点击右下角相机开始扫描', style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: .78),
                  itemCount: _docs.length,
                  itemBuilder: (context, index) {
                    final doc = _docs[index];
                    return _DocumentCard(
                      doc: doc,
                      onChanged: _refresh,
                    );
                  },
                ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'gallery',
            onPressed: _importFromGallery,
            child: const Icon(Icons.photo_library),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.large(
            heroTag: 'capture',
            onPressed: _startCapture,
            child: const Icon(Icons.camera_alt, size: 32),
          ),
        ],
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  final DocumentMeta doc;
  final VoidCallback onChanged;

  const _DocumentCard({required this.doc, required this.onChanged});

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除文档'),
        content: Text('确定删除「${doc.title}」？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await DocumentStore.deleteDocument(doc.id);
      onChanged();
    }
  }

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: doc.title);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '文档标题', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty && newTitle != doc.title) {
      await DocumentStore.renameDocument(doc.id, newTitle);
      onChanged();
    }
  }

  @override
  Widget build(BuildContext context) {
    final thumb = doc.firstThumbPath;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () async {
          await Navigator.push(context, MaterialPageRoute(builder: (_) => EditorScreen(docId: doc.id)));
          onChanged();
        },
        onLongPress: () async {
          // 长按弹出管理菜单：重命名 / 删除
          final action = await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    leading: const Icon(Icons.drive_file_rename_outline),
                    title: const Text('重命名'),
                    onTap: () => Navigator.pop(ctx, 'rename'),
                  ),
                  ListTile(
                    leading: Icon(Icons.delete_outline, color: Theme.of(ctx).colorScheme.error),
                    title: Text('删除文档', style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
                    onTap: () => Navigator.pop(ctx, 'delete'),
                  ),
                ],
              ),
            ),
          );
          if (!context.mounted) return;
          if (action == 'delete') {
            await _confirmDelete(context);
          } else if (action == 'rename' && context.mounted) {
            await _rename(context);
          }
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: thumb != null && File(thumb).existsSync()
                  ? Image.file(File(thumb), fit: BoxFit.cover)
                  : const ColoredBox(color: Colors.black12, child: Icon(Icons.image, size: 48)),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(doc.title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall),
                  Text('${doc.pages.length} 页 · ${_formatDate(doc.createdAt)}',
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatDate(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}

// --------------------------- Capture flow ---------------------------

/// Draft page captured by the camera, pending crop/save (mirrors DraftScanPageEntity).
class DraftPage {
  final int id;
  final RgbaImage original;
  String thumbPath;
  String cropPoints; // "x,y;x,y;x,y;x,y" normalized
  int rotation; // quarter turns
  double confidence;
  DraftPage({
    required this.id,
    required this.original,
    required this.thumbPath,
    required this.cropPoints,
    this.rotation = 0,
    this.confidence = 0,
  });
}

/// Capture flow replicating the original: camera -> drafts accumulate
/// (single: jump straight to crop; multi: stay in camera) -> crop per page
/// (draggable corners + rotate) -> batch process -> save screen.
class CaptureFlowScreen extends StatefulWidget {
  final CaptureMode mode;
  const CaptureFlowScreen({super.key, required this.mode});

  @override
  State<CaptureFlowScreen> createState() => _CaptureFlowScreenState();
}

class _CaptureFlowScreenState extends State<CaptureFlowScreen> {
  final List<DraftPage> _drafts = [];
  String? _message;
  String _selectedFilter = 'None';

  Future<void> _onCaptured(CapturedPage page) async {
    final idBase = _drafts.isEmpty ? await DocumentStore.nextPageId() : (_drafts.last.id + 1);
    final dir = Directory(await DocumentStore.documentsRootPath());
    final sessionDir = Directory('${dir.path}/draft-${DateTime.now().millisecondsSinceEpoch ~/ 100000}');
    await sessionDir.create(recursive: true);
    final thumbFile = File('${sessionDir.path}/$idBase-thumb.jpg');
    // 缩略图与边缘检测已在后台 isolate 完成（见 camera_screen.dart），主线程只写文件
    await thumbFile.writeAsBytes(page.thumbBytes);

    final detection = page.detection;
    final corners = (detection != null && detection.status == DocumentDetectionStatus.detected && detection.corners.length == 4)
        ? detection.corners
        : defaultCropPoints(page.image.width, page.image.height);
    final draft = DraftPage(
      id: idBase,
      original: page.image,
      thumbPath: thumbFile.path,
      cropPoints: corners.map((p) => '${p.x},${p.y}').join(';'),
      confidence: (detection != null && detection.corners.length == 4) ? detection.confidence : 0,
    );
    setState(() {
      _drafts.add(draft);
      _message = '已拍摄 ${_drafts.length} 页';
    });
    if (widget.mode == CaptureMode.single && mounted) {
      // single mode: 打开裁剪页；裁剪页关闭后 CaptureFlow 整体出栈回主界面
      _openCrop(_drafts.length - 1);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(_message!),
        duration: const Duration(seconds: 1),
      ));
    }
  }

  void _openCrop(int index) async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => CropScreen(
          drafts: _drafts,
          initialIndex: index,
          selectedFilter: _selectedFilter,
          onFilterChanged: (f) => _selectedFilter = f,
        ),
      ),
    );
    if (ok == true && mounted) {
      Navigator.of(context).pop(true); // back to home; doc saved inside crop flow
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: CameraCaptureScreen(
        mode: widget.mode,
        onCaptured: _onCaptured,
        onClose: () => Navigator.of(context).pop(),
      ),
      bottomNavigationBar: _drafts.isEmpty
          ? null
          : SafeArea(
              child: Container(
                color: Colors.black87,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final draft in _drafts)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: Image.file(File(draft.thumbPath), width: 44, height: 58, fit: BoxFit.cover),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: () => _openCrop(0),
                      icon: const Icon(Icons.crop),
                      label: Text('裁剪 (${_drafts.length})'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

/// Mirrors the original ClearScan rule: single Document captures jump straight
/// to the crop screen; multi mode keeps accumulating drafts.
bool shouldOpenCropAfterCapture(CaptureMode mode) => mode == CaptureMode.single;

/// Album import: loads picked images as drafts and opens the same crop flow.
class GalleryImportScreen extends StatefulWidget {
  final List<XFile> xFiles;
  final CaptureMode mode;
  const GalleryImportScreen({super.key, required this.xFiles, required this.mode});

  @override
  State<GalleryImportScreen> createState() => _GalleryImportScreenState();
}

class _GalleryImportScreenState extends State<GalleryImportScreen> {
  @override
  void initState() {
    super.initState();
    Future(() async {
      final drafts = <DraftPage>[];
      var idBase = await DocumentStore.nextPageId();
      final root = await DocumentStore.documentsRoot();
      final sessionDir = Directory('${root.path}/draft-import-${DateTime.now().millisecondsSinceEpoch}');
      await sessionDir.create(recursive: true);
      for (var i = 0; i < widget.xFiles.length; i++) {
        final bytes = await widget.xFiles[i].readAsBytes();
        final img = decodeImageBytes(bytes);
        final detection = DocumentEdgeDetector.detect(Uint8ListRgba(img.bytes, img.width, img.height));
        final corners = (detection.status == DocumentDetectionStatus.detected && detection.corners.length == 4)
            ? detection.corners
            : defaultCropPoints(img.width, img.height);
        final thumbFile = File('${sessionDir.path}/${idBase + i}-thumb.jpg');
        await thumbFile.writeAsBytes(encodeJpegBytes(thumbOf(img, 640)));
        drafts.add(DraftPage(
          id: idBase + i,
          original: img,
          thumbPath: thumbFile.path,
          cropPoints: corners.map((p) => '${p.x},${p.y}').join(';'),
          confidence: detection.corners.length == 4 ? detection.confidence : 0,
        ));
      }
      if (!mounted) return;
      // jump straight into the crop flow with all drafts loaded
      final ok = await Navigator.pushReplacement<bool, bool>(
        context,
        MaterialPageRoute(
          builder: (_) => CropScreen(
            drafts: drafts,
            initialIndex: 0,
            selectedFilter: 'None',
            onFilterChanged: (_) {},
          ),
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(ok == true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: CircularProgressIndicator()),
    );
  }
}

List<Point> defaultCropPoints(int width, int height) {
  // default inset frame at 8% margins, normalized
  return const [Point(.08, .08), Point(.92, .08), Point(.92, .92), Point(.08, .92)];
}

/// Crop screen: draggable corner handles + rotate, "下一步" runs the batch
/// crop->enhance->filter pipeline and opens the save screen. Mirrors Screen.Crop.
class CropScreen extends StatefulWidget {
  final List<DraftPage> drafts;
  final int initialIndex;
  final String selectedFilter;
  final ValueChanged<String> onFilterChanged;

  const CropScreen({
    super.key,
    required this.drafts,
    required this.initialIndex,
    required this.selectedFilter,
    required this.onFilterChanged,
  });

  @override
  State<CropScreen> createState() => _CropScreenState();
}

class _CropScreenState extends State<CropScreen> {
  late int _index;
  late List<Point> _points; // normalized
  int _rotation = 0;
  bool _busy = false;
  // 文档级统一滤镜：在裁剪页选定后对所有页生效（局部状态，保证 chip 可点选）。
  late String _selectedFilter;
  // 批处理进度：正在处理第几页/共几页（用于加载层显示）
  int _progressPage = 0;
  int _progressTotal = 0;

  // 放大镜状态：当前拖拽的角点索引（-1 = 未拖拽）
  int _draggingIndex = -1;
  // 放大镜中心在画面坐标系（display space）中的位置
  double _magnifierX = 0, _magnifierY = 0;
  // 手柄与放大镜的尺寸常量
  static const double _handleVisualSize = 36;
  static const double _handleTouchSize = 64;
  static const double _magnifierSize = 120;
  static const double _magnifierZoom = 3.0;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _selectedFilter = widget.selectedFilter;
    _loadPoints();
  }

  void _loadPoints() {
    final d = widget.drafts[_index];
    setState(() {
      _rotation = d.rotation;
      _points = d.cropPoints.isEmpty
          ? defaultCropPoints(1, 1)
          : [
              for (final pair in d.cropPoints.split(';'))
                Point(double.parse(pair.split(',')[0]), double.parse(pair.split(',')[1])),
            ];
    });
  }

  void _savePointsToDraft() {
    widget.drafts[_index].cropPoints = _points.map((p) => '${p.x},${p.y}').join(';');
    widget.drafts[_index].rotation = _rotation;
  }


  void _rotate() {
    setState(() => _rotation = (_rotation + 1) % 4);
    // 旋转后立即持久化到草稿，避免用户直接返回时丢失旋转状态
    _savePointsToDraft();
  }

  Future<void> _next() async {
    _savePointsToDraft();
    setState(() => _busy = true);
    // advance to next uncropped page or finish
    if (_index < widget.drafts.length - 1) {
      setState(() {
        _index += 1;
        _busy = false;
      });
      _loadPoints();
    } else {
      try {
        await _finishAll();
      } catch (e, stack) {
        // 批处理失败：明确报错并留在裁剪页，让用户重试或调整角点
        if (!mounted) return;
        setState(() => _busy = false);
        showErrorDialog(context, '处理失败', e, stack);
      }
    }
  }

  Future<void> _finishAll() async {
    // batch: crop -> enhance -> selected filter for every draft
    // 契约：cropPoints 是未旋转原图坐标系的归一化角点，先裁剪再旋转
    setState(() {
      _progressPage = 0;
      _progressTotal = widget.drafts.length;
    });
    final docId = await DocumentStore.nextDocumentId();
    var pageId = widget.drafts.first.id;
    final pages = <StoredPage>[];
    final root = await DocumentStore.documentsRoot();
    final dir = Directory('${root.path}/$docId');
    await dir.create(recursive: true);

    for (var i = 0; i < widget.drafts.length; i++) {
      final draft = widget.drafts[i];
      final corners = [
        for (final pair in draft.cropPoints.split(';'))
          Point(double.parse(pair.split(',')[0]), double.parse(pair.split(',')[1])),
      ];
      // 先按角点在原图上裁剪，再应用旋转，保证坐标系一致。
      // 裁剪失败直接抛出，绝不静默降级为未裁剪的原图
      setState(() => _progressPage = i + 1);
      RgbaImage processed;
      try {
        processed = DocumentPerspectiveCorrector.crop(draft.original, corners);
      } catch (e) {
        throw StateError('第 ${i + 1} 页裁剪失败: $e');
      }
      processed = rotateQuarters(processed, draft.rotation);
      var enhanced = ImageProcessor.enhanceDocument(processed);
      if (_selectedFilter != 'None') {
        enhanced = ImageProcessor.filter(enhanced, _selectedFilter);
      }
      final id = pageId + i;
      final originalPath = '${dir.path}/$id-original.jpg';
      final processedPath = '${dir.path}/$id-processed.jpg';
      final thumbPath = '${dir.path}/$id-thumb.jpg';
      await File(originalPath).writeAsBytes(encodeJpegBytes(draft.original));
      await File(processedPath).writeAsBytes(encodeJpegBytes(enhanced));
      await File(thumbPath).writeAsBytes(encodeJpegBytes(thumbOf(enhanced, 320)));
      pages.add(StoredPage(
        id: id,
        pageIndex: i,
        originalPath: originalPath,
        processedPath: processedPath,
        thumbPath: thumbPath,
        cropPoints: draft.cropPoints,
        filter: _selectedFilter,
        rotation: draft.rotation,
        confidence: draft.confidence,
        width: enhanced.width,
        height: enhanced.height,
      ));
    }
    if (!mounted) return;
    // open save screen for title entry
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SaveScreen(docId: docId, pages: pages),
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop(saved == true);
  }

  /// Display-space position of a normalized point, accounting for quarter rotation.
  /// After k clockwise quarter turns, the displayed image maps the source point:
  ///   k=0: (x, y); k=1: (1-y, x); k=2: (1-x, 1-y); k=3: (y, 1-x)
  double _dispX(Point p) {
    switch (_rotation % 4) {
      case 1: return 1 - p.y;
      case 2: return 1 - p.x;
      case 3: return p.y;
      default: return p.x;
    }
  }

  double _dispY(Point p) {
    switch (_rotation % 4) {
      case 1: return p.x;
      case 2: return 1 - p.y;
      case 3: return 1 - p.x;
      default: return p.y;
    }
  }

  /// 复位裁剪框：四角归位到画面中央一半大小的矩形（不旋转坐标系）。
  void _resetToCenterRect() {
    setState(() {
      _points = [
        const Point(.25, .25),
        const Point(.75, .25),
        const Point(.75, .75),
        const Point(.25, .75),
      ];
    });
    _savePointsToDraft();
  }

  /// Drag: convert display delta back to normalized source delta (inverse mapping).
  void _dragPoint(int i, Offset delta, double dispW, double dispH) {
    final dx = delta.dx / dispW;
    final dy = delta.dy / dispH;
    double nx = _points[i].x, ny = _points[i].y;
    switch (_rotation % 4) {
      case 1: nx += dy; ny -= dx; break;
      case 2: nx -= dx; ny -= dy; break;
      case 3: nx -= dy; ny += dx; break;
      default: nx += dx; ny += dy;
    }
    setState(() {
      _points[i] = Point(nx.clamp(0.0, 1.0), ny.clamp(0.0, 1.0));
      _draggingIndex = i;
      _magnifierX = _dispX(_points[i]) * dispW;
      _magnifierY = _dispY(_points[i]) * dispH;
    });
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.drafts[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text('裁剪 ${_index + 1}/${widget.drafts.length}'),
        actions: [
          IconButton(icon: const Icon(Icons.crop_free), onPressed: _resetToCenterRect, tooltip: '复位裁剪框'),
          IconButton(icon: const Icon(Icons.rotate_right), onPressed: _rotate, tooltip: '旋转'),
          TextButton(
            onPressed: _busy ? null : _next,
            child: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('下一步'),
          ),
        ],
      ),
      body: _busy
          ? Center(
              // 批处理加载层：可见的进度反馈（滤镜应用发生在这一步）
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(
                    '正在处理第 $_progressPage/$_progressTotal 页',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _selectedFilter == 'None'
                        ? '应用文档增强'
                        : '应用滤镜: $_selectedFilter',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            )
          : LayoutBuilder(builder: (context, constraints) {
              // rotated display dimensions
              final ow = draft.original.width, oh = draft.original.height;
              final rotatedOdd = _rotation % 2 == 1;
              final imgW = rotatedOdd ? oh : ow;
              final imgH = rotatedOdd ? ow : oh;
              final imgAspect = imgW / imgH;
              final boxW = constraints.maxWidth, boxH = constraints.maxHeight;
              double dispW, dispH;
              if (boxW / boxH > imgAspect) {
                dispH = boxH;
                dispW = dispH * imgAspect;
              } else {
                dispW = boxW;
                dispH = dispW / imgAspect;
              }
              final offX = (boxW - dispW) / 2;
              final offY = (boxH - dispH) / 2;

              Widget handle(int i) {
                final cx = offX + _dispX(_points[i]) * dispW;
                final cy = offY + _dispY(_points[i]) * dispH;
                return Positioned(
                  left: 0, top: 0,
                  child: Transform.translate(
                    // 角点必须位于触控容器（64px）的正中心：
                    // 容器左上角 = 角点 - 半个触控区，视觉圆在容器内居中，
                    // 圆心即角点。之前偏移量误用了视觉尺寸的一半，
                    // 导致圆心向右下偏移半个触控区（32px）
                    offset: Offset(
                      cx - _handleTouchSize / 2,
                      cy - _handleTouchSize / 2,
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanStart: (_) => setState(() => _draggingIndex = i),
                      onPanUpdate: (d) => _dragPoint(i, d.delta, dispW, dispH),
                      onPanEnd: (_) {
                        _savePointsToDraft();
                        setState(() => _draggingIndex = -1);
                      },
                      onPanCancel: () => setState(() => _draggingIndex = -1),
                      child: Container(
                        // 触控热区 64px（Material 建议最小 48px），视觉圆 36px
                        width: _handleTouchSize,
                        height: _handleTouchSize,
                        color: Colors.transparent,
                        alignment: Alignment.center,
                        child: Container(
                          width: _handleVisualSize,
                          height: _handleVisualSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: .85),
                            border: Border.all(
                              color: Theme.of(context).colorScheme.primary,
                              width: 3,
                            ),
                            boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 4)],
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }

              // quad outline in display space
              Path quadPath() {
                final path = Path();
                for (var i = 0; i < 4; i++) {
                  final p = _points[i];
                  final px = offX + _dispX(p) * dispW;
                  final py = offY + _dispY(p) * dispH;
                  if (i == 0) { path.moveTo(px, py); } else { path.lineTo(px, py); }
                }
                return path..close();
              }

              return Stack(
                children: [
                  Positioned(
                    left: offX, top: offY,
                    child: SizedBox(
                      width: dispW, height: dispH,
                      child: ClipRect(
                        child: Image.file(
                          File(draft.thumbPath),
                          fit: BoxFit.fill,
                          alignment: Alignment.center,
                        ),
                      ),
                    ),
                  ),
                  // dim outside quad
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _QuadOverlayPainter(quadPath()),
                    ),
                  ),
                  // corner handles
                  for (var i = 0; i < 4; i++) handle(i),
                  // 放大镜 + 准星：拖动角点时显示在画面内角点附近
                  if (_draggingIndex >= 0)
                    _MagnifierCrosshair(
                      imageFile: File(draft.thumbPath),
                      sourceX: _dispX(_points[_draggingIndex]),
                      sourceY: _dispY(_points[_draggingIndex]),
                      anchorX: offX + _magnifierX,
                      anchorY: offY + _magnifierY,
                      boxWidth: boxW,
                      boxHeight: boxH,
                      size: _magnifierSize,
                      zoom: _magnifierZoom,
                    ),
                  if (widget.drafts.length > 1)
                    Positioned(
                      left: 12, bottom: 12,
                      child: Text('${_index + 1} / ${widget.drafts.length}',
                          style: const TextStyle(color: Colors.white70)),
                    ),
                ],
              );
            }),
      bottomNavigationBar: SafeArea(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final f in ['None', 'Enhanced', 'Smart Gray', 'Magic Color', 'B&W', 'Ink', 'White Paper'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f == 'None' ? '原图' : (f == 'Enhanced' ? '增强' : f)),
                    selected: _selectedFilter == f,
                    onSelected: (_) {
                      setState(() => _selectedFilter = f);
                      widget.onFilterChanged(f);
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dim overlay outside the crop quad.
class _QuadOverlayPainter extends CustomPainter {
  final Path quad;
  _QuadOverlayPainter(this.quad);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path.combine(PathOperation.difference, Path()..addRect(Offset.zero & size), quad),
      Paint()..color = const Color(0x66000000),
    );
    canvas.drawPath(quad, Paint()..color = Colors.white..style = PaintingStyle.stroke..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(covariant _QuadOverlayPainter old) => old.quad != quad;
}

/// Save screen: title entry, then persist. Mirrors Screen.Save.
class SaveScreen extends StatefulWidget {
  final int docId;
  final List<StoredPage> pages;
  const SaveScreen({super.key, required this.docId, required this.pages});

  @override
  State<SaveScreen> createState() => _SaveScreenState();
}

class _SaveScreenState extends State<SaveScreen> {
  late final TextEditingController _title;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _title = TextEditingController(text: '扫描 ${now.month}-${now.day} ${widget.pages.length}页');
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final meta = DocumentMeta(
      id: widget.docId,
      title: _title.text.trim().isEmpty ? '未命名' : _title.text.trim(),
      createdAt: DateTime.now().millisecondsSinceEpoch,
      pages: widget.pages,
    );
    await DocumentStore.saveDocument(meta);
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('保存')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _title,
              decoration: const InputDecoration(labelText: '文档标题', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Text('${widget.pages.length} 页', style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.save),
              label: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}

// ------------------------------ Editor ------------------------------

/// Page editor: view processed pages, re-run filters, rotate, delete, export PDF/image.
class EditorScreen extends StatefulWidget {
  final int docId;
  const EditorScreen({super.key, required this.docId});

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> {
  DocumentMeta? _meta;
  int _index = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final meta = await DocumentStore.readMeta(widget.docId);
    if (!mounted) return;
    setState(() => _meta = meta);
  }

  /// 保存当前页处理图为 JPEG 到导出目录。
  Future<void> _exportImage() async {
    final meta = _meta;
    if (meta == null || _busy) return;
    setState(() => _busy = true);
    try {
      final page = meta.pages[_index.clamp(0, meta.pages.length - 1)];
      final name = '${safeFileName(meta.title)}-${page.pageIndex + 1}.jpg';
      final dir = await exportDirectory();
      final file = File(p.join(dir.path, name));
      await File(page.processedPath).copy(file.path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('图片已保存: ${file.path}')));
      }
    } catch (e, stack) {
      if (mounted) {
        showErrorDialog(context, '保存失败', e, stack);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出全部页为 PDF 到导出目录。
  Future<void> _exportPdf() async {
    final meta = _meta;
    if (meta == null || _busy) return;
    setState(() => _busy = true);
    try {
      final pdf = pw.Document();
      for (final page in meta.pages) {
        final bytes = await File(page.processedPath).readAsBytes();
        final image = pw.MemoryImage(bytes);
        pdf.addPage(pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
        ));
      }
      final pdfBytes = await pdf.save();
      final name = '${safeFileName(meta.title)}.pdf';
      final dir = await exportDirectory();
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(pdfBytes);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('PDF 已导出: ${file.path}')));
      }
    } catch (e, stack) {
      if (mounted) {
        showErrorDialog(context, '导出失败', e, stack);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }


  /// 对当前页重新应用滤镜：从原始图按存储的裁剪框/旋转重新裁剪->增强->滤镜，
  /// 覆盖写回 processed/thumb，并把 filter 固定到该页（文档内的单独设置）。
  Future<void> _applyFilter(String filter) async {
    final meta = _meta;
    if (meta == null || _busy) return;
    final page = meta.pages[_index.clamp(0, meta.pages.length - 1)];
    setState(() => _busy = true);
    try {
      final original = decodeImageBytes(await File(page.originalPath).readAsBytes());
      final corners = [
        for (final pair in page.cropPoints.split(';'))
          if (pair.isNotEmpty) Point(double.parse(pair.split(',')[0]), double.parse(pair.split(',')[1])),
      ];
      RgbaImage processed = original;
      if (corners.length == 4) {
        processed = DocumentPerspectiveCorrector.crop(original, corners);
      }
      processed = rotateQuarters(processed, page.rotation);
      var enhanced = ImageProcessor.enhanceDocument(processed);
      if (filter != 'None') enhanced = ImageProcessor.filter(enhanced, filter);
      await File(page.processedPath).writeAsBytes(encodeJpegBytes(enhanced));
      await File(page.thumbPath).writeAsBytes(encodeJpegBytes(thumbOf(enhanced, 320)));
      final updated = [...meta.pages];
      updated[_index.clamp(0, meta.pages.length - 1)] = page.copyWithFilter(filter);
      await DocumentStore.saveDocument(meta.copyWith(pages: updated));
      if (mounted) setState(() {});
      await _load();
    } catch (e, stack) {
      if (mounted) showErrorDialog(context, '应用滤镜失败', e, stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 删除当前页（仅多页文档可用），页序号重排。
  Future<void> _deletePage() async {
    final meta = _meta;
    if (meta == null || meta.pages.length <= 1) return;
    final pages = [...meta.pages]..removeAt(_index);
    for (var i = 0; i < pages.length; i++) {
      pages[i] = StoredPage(
        id: pages[i].id, pageIndex: i, originalPath: pages[i].originalPath,
        processedPath: pages[i].processedPath, thumbPath: pages[i].thumbPath,
        cropPoints: pages[i].cropPoints, filter: pages[i].filter,
        confidence: pages[i].confidence, width: pages[i].width, height: pages[i].height,
      );
    }
    await DocumentStore.saveDocument(meta.copyWith(pages: pages));
    if (mounted) setState(() { _index = _index.clamp(0, pages.length - 1); });
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta;
    if (meta == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final page = meta.pages.isEmpty ? null : meta.pages[_index.clamp(0, meta.pages.length - 1)];
    return Scaffold(
      appBar: AppBar(
        title: Text(meta.title),
        actions: [
          IconButton(icon: const Icon(Icons.image_outlined), onPressed: _exportImage, tooltip: '保存为图片'),
          IconButton(icon: const Icon(Icons.picture_as_pdf), onPressed: _exportPdf, tooltip: '导出 PDF'),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: meta.pages.length > 1 ? _deletePage : null,
            tooltip: '删除本页',
          ),
        ],
      ),
      body: _busy || page == null
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: Center(child: Image.file(File(page.processedPath), fit: BoxFit.contain)),
                  ),
                ),
                SizedBox(
                  height: 96,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: meta.pages.length,
                    itemBuilder: (context, i) => GestureDetector(
                      onTap: () => setState(() => _index = i),
                      child: Container(
                        margin: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: i == _index ? Theme.of(context).colorScheme.primary : Colors.transparent,
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: Image.file(File(meta.pages[i].thumbPath), width: 60, fit: BoxFit.cover),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        // 文档级滤镜在裁剪阶段选定；此处可对当前页单独覆盖。
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final f in ['None', 'Enhanced', 'Smart Gray', 'Magic Color', 'B&W', 'Ink', 'White Paper'])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f == 'None' ? '原图' : (f == 'Enhanced' ? '增强' : f)),
                      selected: page!.filter == f,
                      onSelected: _busy ? null : (_) => _applyFilter(f),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}


/// 拖动裁切角点时的放大镜 + 准星。
///
/// 实现：[FutureBuilder] 解码 thumb 图后交给 [CustomPainter]，painter 直接
/// 用 drawImageRect 把角点周围的小区域拉伸画满整个圆形区域——源/目标矩形
/// 都是显式计算，图像必然跟随角点移动且放大倍数精确。
class _MagnifierCrosshair extends StatelessWidget {
  final File imageFile;
  final double sourceX; // 角点在显示图中的归一化位置 (0..1)
  final double sourceY;
  final double anchorX; // 角点在画面中的绝对坐标
  final double anchorY;
  final double boxWidth; // 裁剪画面尺寸（放大镜从手指位置向中心避让）
  final double boxHeight;
  final double size; // 放大镜直径（逻辑像素）
  final double zoom; // 放大倍数：镜内 1 逻辑像素 = 源图 1/zoom 像素

  const _MagnifierCrosshair({
    required this.imageFile,
    required this.sourceX,
    required this.sourceY,
    required this.anchorX,
    required this.anchorY,
    required this.boxWidth,
    required this.boxHeight,
    required this.size,
    required this.zoom,
  });

  @override
  Widget build(BuildContext context) {
    // 放大镜中心：从角点沿指向画面中心的方向偏移，避免遮挡手指
    final centerX = boxWidth / 2;
    final centerY = boxHeight / 2;
    final dirX = centerX - anchorX;
    final dirY = centerY - anchorY;
    final len = math.sqrt(dirX * dirX + dirY * dirY);
    final norm = len > 1 ? 1.0 / len : 0.0;
    final offset = size / 2 + 56;
    final mgX = (anchorX + dirX * norm * offset).clamp(size / 2 + 4, boxWidth - size / 2 - 4);
    final mgY = (anchorY + dirY * norm * offset).clamp(size / 2 + 4, boxHeight - size / 2 - 4);

    return Positioned(
      left: 0,
      top: 0,
      child: Transform.translate(
        offset: Offset(mgX - size / 2, mgY - size / 2),
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 8, spreadRadius: 1)],
          ),
          child: ClipOval(
            child: FutureBuilder<ui.Image>(
              future: _loadImage(),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const ColoredBox(color: Colors.black38);
                }
                return CustomPaint(
                  painter: _MagnifierPainter(
                    image: snapshot.data!,
                    sourceX: sourceX,
                    sourceY: sourceY,
                    zoom: zoom,
                  ),
                  child: const CustomPaint(painter: _CrosshairPainter()),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// 解码并缓存 thumb 图（同一文件多次进入只解码一次）。
  static ui.Image? _cached;
  static String? _cachedPath;

  Future<ui.Image> _loadImage() async {
    final path = imageFile.path;
    if (_cached != null && _cachedPath == path) return _cached!;
    final bytes = await imageFile.readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    _cached = frame.image;
    _cachedPath = path;
    return _cached!;
  }
}

/// 放大镜核心绘制：把角点周围 size/zoom 的源图区域画满整个圆形画布。
class _MagnifierPainter extends CustomPainter {
  final ui.Image image;
  final double sourceX;
  final double sourceY;
  final double zoom;

  const _MagnifierPainter({
    required this.image,
    required this.sourceX,
    required this.sourceY,
    required this.zoom,
  });

  @override
  void paint(Canvas canvas, Size canvasSize) {
    // 角点在 thumb 位图中的像素坐标（显示图与位图同构，归一化坐标直接映射）
    final px = sourceX * image.width;
    final py = sourceY * image.height;
    // 取角点周围一个正方形源区域，放大后恰好填满画布
    final srcHalf = canvasSize.width / zoom / 2;
    final src = Rect.fromCenter(
      center: Offset(px, py),
      width: srcHalf * 2,
      height: srcHalf * 2,
    );
    // 源区域可能越出位图边界：向内平移使其完整落在位图内
    final dx = src.left < 0 ? -src.left : (src.right > image.width.toDouble() ? image.width.toDouble() - src.right : 0.0);
    final dy = src.top < 0 ? -src.top : (src.bottom > image.height.toDouble() ? image.height.toDouble() - src.bottom : 0.0);
    final clampedSrc = src.shift(Offset(dx, dy));
    final dst = Offset.zero & canvasSize;
    final paint = Paint()..filterQuality = FilterQuality.medium;
    canvas.drawImageRect(image, clampedSrc, dst, paint);
  }

  @override
  bool shouldRepaint(covariant _MagnifierPainter old) =>
      old.sourceX != sourceX || old.sourceY != sourceY || old.image != image;
}

/// 放大镜内的准星绘制：中心圆点 + 上下左右短刻线。
class _CrosshairPainter extends CustomPainter {
  const _CrosshairPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final paintLine = Paint()
      ..color = const Color(0xCC00E5FF)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    const gap = 8.0, len = 12.0;
    canvas.drawLine(c.translate(0, -gap - len), c.translate(0, -gap), paintLine);
    canvas.drawLine(c.translate(0, gap), c.translate(0, gap + len), paintLine);
    canvas.drawLine(c.translate(-gap - len, 0), c.translate(-gap, 0), paintLine);
    canvas.drawLine(c.translate(gap, 0), c.translate(gap + len, 0), paintLine);
    canvas.drawCircle(c, 6.5, paintLine);
    canvas.drawCircle(c, 1.5, Paint()..color = const Color(0xFF00E5FF));
  }

  @override
  bool shouldRepaint(covariant _CrosshairPainter oldDelegate) => false;
}
