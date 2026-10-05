// ClearScan Flutter - main app: home list, capture flow, editor, export
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:io';
import 'dart:typed_data';

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
  final bool _processing = false;
  String? _message;
  String _selectedFilter = 'None';

  Future<void> _onCaptured(CapturedPage page) async {
    final idBase = _drafts.isEmpty ? await DocumentStore.nextPageId() : (_drafts.last.id + 1);
    final dir = Directory(await DocumentStore.documentsRootPath());
    final sessionDir = Directory('${dir.path}/draft-${DateTime.now().millisecondsSinceEpoch ~/ 100000}');
    await sessionDir.create(recursive: true);
    final thumbFile = File('${sessionDir.path}/$idBase-thumb.jpg');
    await thumbFile.writeAsBytes(encodeJpegBytes(thumbOf(page.image, 640)));

    // post-capture detection (single-shot, matching original onCapture path)
    final detection = DocumentEdgeDetector.detect(Uint8ListRgba(page.image.bytes, page.image.width, page.image.height));
    final corners = (detection.status == DocumentDetectionStatus.detected && detection.corners.length == 4)
        ? detection.corners
        : defaultCropPoints(page.image.width, page.image.height);
    final draft = DraftPage(
      id: idBase,
      original: page.image,
      thumbPath: thumbFile.path,
      cropPoints: corners.map((p) => '${p.x},${p.y}').join(';'),
      confidence: detection.corners.length == 4 ? detection.confidence : 0,
    );
    setState(() {
      _drafts.add(draft);
      _message = '已拍摄 ${_drafts.length} 页';
    });
    if (widget.mode == CaptureMode.single && mounted) {
      // single mode: open crop immediately for the captured page
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
                      onPressed: _processing ? null : () => _openCrop(0),
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

RgbaImage thumbOf(RgbaImage src, int maxSide) {
  final scale = maxSide / (src.width > src.height ? src.width : src.height);
  if (scale >= 1) return src;
  final w = (src.width * scale).round(), h = (src.height * scale).round();
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final sy = (y / scale).round().clamp(0, src.height - 1);
    for (var x = 0; x < w; x++) {
      final sx = (x / scale).round().clamp(0, src.width - 1);
      final so = (sy * src.width + sx) * 4;
      final o = (y * w + x) * 4;
      out[o] = src.bytes[so]; out[o + 1] = src.bytes[so + 1];
      out[o + 2] = src.bytes[so + 2]; out[o + 3] = 255;
    }
  }
  return RgbaImage(out, w, h);
}

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

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
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
      await _finishAll();
    }
  }

  Future<void> _finishAll() async {
    // batch: crop -> enhance -> selected filter for every draft
    // 契约：cropPoints 是未旋转原图坐标系的归一化角点，先裁剪再旋转
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
      // 先按角点在原图上裁剪，再应用旋转，保证坐标系一致
      RgbaImage processed;
      try {
        processed = DocumentPerspectiveCorrector.crop(draft.original, corners);
      } catch (_) {
        processed = draft.original;
      }
      processed = rotateQuarters(processed, draft.rotation);
      var enhanced = ImageProcessor.enhanceDocument(processed);
      if (widget.selectedFilter != 'None') {
        enhanced = ImageProcessor.filter(enhanced, widget.selectedFilter);
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
        filter: widget.selectedFilter,
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final draft = widget.drafts[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text('裁剪 ${_index + 1}/${widget.drafts.length}'),
        actions: [
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
          ? const Center(child: Text('批量处理中…'))
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
                return Positioned(
                  left: 0, top: 0,
                  child: Transform.translate(
                    offset: Offset(
                      offX + _dispX(_points[i]) * dispW - 16,
                      offY + _dispY(_points[i]) * dispH - 16,
                    ),
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onPanUpdate: (d) => setState(() => _dragPoint(i, d.delta, dispW, dispH)),
                      onPanEnd: (_) => _savePointsToDraft(),
                      child: Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: .85),
                          border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
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
                    selected: widget.selectedFilter == f,
                    onSelected: (_) {
                      widget.onFilterChanged(f);
                      setState(() {});
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

  Future<void> _applyFilter(String filter) async {
    final meta = _meta;
    if (meta == null || _busy) return;
    setState(() => _busy = true);
    try {
      final pages = [...meta.pages];
      final page = pages[_index];
      final original = decodeImageBytes(await File(page.originalPath).readAsBytes());
      // 重推导管线与保存时一致：原图角点裁剪 -> 应用旋转 -> 滤镜
      RgbaImage processed;
      if (page.cropPoints.isNotEmpty) {
        final corners = [
          for (final pair in page.cropPoints.split(';'))
            Point(double.parse(pair.split(',')[0]), double.parse(pair.split(',')[1])),
        ];
        try {
          processed = DocumentPerspectiveCorrector.crop(original, corners);
        } catch (_) {
          processed = original;
        }
      } else {
        processed = original;
      }
      if (page.rotation != 0) {
        processed = rotateQuarters(processed, page.rotation);
      }
      final result = filter == 'Enhanced'
          ? ImageProcessor.enhanceDocument(processed)
          : ImageProcessor.filter(processed, filter);
      await File(page.processedPath).writeAsBytes(encodeJpegBytes(result));
      await File(page.thumbPath)
          .writeAsBytes(encodeJpegBytes(_thumbnailOf(result, 320)));
      pages[_index] = StoredPage(
        id: page.id,
        pageIndex: page.pageIndex,
        originalPath: page.originalPath,
        processedPath: page.processedPath,
        thumbPath: page.thumbPath,
        cropPoints: page.cropPoints,
        filter: filter,
        rotation: page.rotation,
        confidence: page.confidence,
        width: result.width,
        height: result.height,
      );
      await DocumentStore.saveDocument(meta.copyWith(pages: pages));
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已应用滤镜: ${filter == 'Enhanced' ? '增强' : filter}'),
          duration: const Duration(seconds: 1),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('滤镜处理失败: $e'),
          duration: const Duration(seconds: 2),
        ));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('保存失败: $e')));
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
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  static RgbaImage _thumbnailOf(RgbaImage src, int maxSide) {
    final scale = maxSide / (src.width > src.height ? src.width : src.height);
    if (scale >= 1) return src;
    final w = (src.width * scale).round(), h = (src.height * scale).round();
    final out = Uint8List(w * h * 4);
    for (var y = 0; y < h; y++) {
      final sy = (y / scale).round().clamp(0, src.height - 1);
      for (var x = 0; x < w; x++) {
        final sx = (x / scale).round().clamp(0, src.width - 1);
        final so = (sy * src.width + sx) * 4;
        final o = (y * w + x) * 4;
        out[o] = src.bytes[so]; out[o + 1] = src.bytes[so + 1];
        out[o + 2] = src.bytes[so + 2]; out[o + 3] = 255;
      }
    }
    return RgbaImage(out, w, h);
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
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              for (final f in ['Enhanced', 'Smart Gray', 'Magic Color', 'B&W', 'Ink', 'White Paper'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _applyFilter(f),
                    child: Text(f == 'Enhanced' ? '增强' : f),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
