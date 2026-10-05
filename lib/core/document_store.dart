// Dart port of DocumentStore.kt + ClearScanDatabase.kt (storage layer)
// Copyright (c) 2026 ant-cave (AGPL-3.0-or-later), original Kotlin (c) SuiYueMengHen (MIT)
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One page of a saved document. `originalPath` is the untouched capture,
/// `processedPath` is the cropped/filtered result and `thumbPath` is the
/// thumbnail of the processed image. Crop/filter parameters allow re-deriving
/// the processed image from the original at any time.
class StoredPage {
  final int id;
  final int pageIndex;
  final String originalPath;
  final String processedPath;
  final String thumbPath;
  final String cropPoints;
  final String filter;
  final double brightness;
  final double contrast;
  final double saturation;
  final int rotation;
  final double confidence;
  final int width;
  final int height;

  const StoredPage({
    required this.id,
    required this.pageIndex,
    required this.originalPath,
    required this.processedPath,
    required this.thumbPath,
    required this.cropPoints,
    this.filter = 'None',
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
    this.rotation = 0,
    this.confidence = 0,
    this.width = 0,
    this.height = 0,
  });

  Map<String, Object> toRow(int documentId) => {
        'id': id,
        'documentId': documentId,
        'pageIndex': pageIndex,
        'originalPath': originalPath,
        'processedPath': processedPath,
        'thumbnailPath': thumbPath,
        'cropPoints': cropPoints,
        'filter': filter,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'rotation': rotation,
        'confidence': confidence,
        'originalWidth': width,
        'originalHeight': height,
      };

  factory StoredPage.fromRow(Map<String, Object?> row) => StoredPage(
        id: row['id'] as int,
        pageIndex: (row['pageIndex'] as int?) ?? 0,
        originalPath: (row['originalPath'] as String?) ?? '',
        processedPath: (row['processedPath'] as String?) ?? '',
        thumbPath: (row['thumbnailPath'] as String?) ?? '',
        cropPoints: (row['cropPoints'] as String?) ?? '',
        filter: (row['filter'] as String?) ?? 'None',
        brightness: ((row['brightness'] as num?) ?? 0).toDouble(),
        contrast: ((row['contrast'] as num?) ?? 1).toDouble(),
        saturation: ((row['saturation'] as num?) ?? 1).toDouble(),
        rotation: (row['rotation'] as int?) ?? 0,
        confidence: ((row['confidence'] as num?) ?? 0).toDouble(),
        width: (row['originalWidth'] as int?) ?? 0,
        height: (row['originalHeight'] as int?) ?? 0,
      );

  factory StoredPage.fromJsonMap(Map<String, Object?> json, {int fallbackIndex = 0}) => StoredPage(
        id: json['id'] as int,
        pageIndex: (json['pageIndex'] as int?) ?? fallbackIndex,
        originalPath: (json['originalPath'] as String?) ?? '',
        processedPath: (json['processedPath'] as String?) ?? '',
        thumbPath: (json['thumbPath'] as String?) ?? '',
        cropPoints: (json['cropPoints'] as String?) ?? '',
        filter: (json['filter'] as String?) ?? 'None',
        brightness: ((json['brightness'] as num?) ?? 0).toDouble(),
        contrast: ((json['contrast'] as num?) ?? 1).toDouble(),
        saturation: ((json['saturation'] as num?) ?? 1).toDouble(),
        rotation: (json['rotation'] as int?) ?? 0,
        confidence: ((json['confidence'] as num?) ?? 0).toDouble(),
        width: (json['width'] as int?) ?? 0,
        height: (json['height'] as int?) ?? 0,
      );

  Map<String, Object> toJson() => {
        'id': id,
        'pageIndex': pageIndex,
        'originalPath': originalPath,
        'processedPath': processedPath,
        'thumbPath': thumbPath,
        'cropPoints': cropPoints,
        'filter': filter,
        'brightness': brightness,
        'contrast': contrast,
        'saturation': saturation,
        'rotation': rotation,
        'confidence': confidence,
        'width': width,
        'height': height,
      };

  /// 仅替换滤镜名（编辑器内单独设置某页滤镜时复用其余字段）。
  StoredPage copyWithFilter(String filter) => StoredPage(
        id: id,
        pageIndex: pageIndex,
        originalPath: originalPath,
        processedPath: processedPath,
        thumbPath: thumbPath,
        cropPoints: cropPoints,
        filter: filter,
        brightness: brightness,
        contrast: contrast,
        saturation: saturation,
        rotation: rotation,
        confidence: confidence,
        width: width,
        height: height,
      );
}

/// Document-level metadata, persisted as metadata.json inside each document folder.
class DocumentMeta {
  final int id;
  final String title;
  final int createdAt;
  final String scanMode;
  final List<StoredPage> pages;

  const DocumentMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    this.scanMode = 'Document',
    this.pages = const [],
  });

  String? get firstThumbPath => pages.isEmpty ? null : pages.first.thumbPath;

  DocumentMeta copyWith({String? title, List<StoredPage>? pages}) => DocumentMeta(
        id: id,
        title: title ?? this.title,
        createdAt: createdAt,
        scanMode: scanMode,
        pages: pages ?? this.pages,
      );

  Map<String, Object> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'scanMode': scanMode,
        'pages': [for (final page in pages) page.toJson()],
      };

  factory DocumentMeta.fromJsonMap(Map<String, Object?> root) {
    final pagesRaw = (root['pages'] as List?) ?? const [];
    return DocumentMeta(
      id: root['id'] as int,
      title: (root['title'] as String?) ?? '',
      createdAt: (root['createdAt'] as num?)?.toInt() ?? 0,
      scanMode: (root['scanMode'] as String?) ?? 'Document',
      pages: [
        for (var i = 0; i < pagesRaw.length; i++)
          StoredPage.fromJsonMap((pagesRaw[i] as Map).cast<String, Object?>(), fallbackIndex: i),
      ],
    );
  }
}

/// Storage layout (all under the app documents directory):
///
///   documents/{docId}/metadata.json
///   documents/{docId}/{pageId}-original.jpg
///   documents/{docId}/{pageId}-processed.jpg
///   documents/{docId}/{pageId}-thumb.jpg
class DocumentStore {
  static Database? _db;

  static Future<String> documentsRootPath() async {
    final base = await getDatabasesPath();
    return p.dirname(base);
  }

  static Future<Directory> documentsRoot() async {
    final parent = await documentsRootPath();
    final dir = Directory(p.join(parent, 'documents'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Database> database() async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), 'clearscan.db');
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS documents (
            id INTEGER NOT NULL PRIMARY KEY,
            title TEXT NOT NULL,
            createdAt INTEGER NOT NULL,
            pageCount INTEGER NOT NULL DEFAULT 0,
            thumbnailPath TEXT NOT NULL DEFAULT '',
            sizeBytes INTEGER NOT NULL DEFAULT 0,
            scanMode TEXT NOT NULL DEFAULT 'Document'
          )''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS scan_pages (
            id INTEGER NOT NULL PRIMARY KEY,
            documentId INTEGER NOT NULL,
            pageIndex INTEGER NOT NULL DEFAULT 0,
            originalPath TEXT NOT NULL,
            processedPath TEXT NOT NULL,
            thumbnailPath TEXT NOT NULL,
            cropPoints TEXT NOT NULL,
            filter TEXT NOT NULL DEFAULT 'None',
            brightness REAL NOT NULL DEFAULT 0,
            contrast REAL NOT NULL DEFAULT 1,
            saturation REAL NOT NULL DEFAULT 1,
            rotation INTEGER NOT NULL DEFAULT 0,
            confidence REAL NOT NULL DEFAULT 0,
            sourceType TEXT NOT NULL DEFAULT 'Document',
            originalWidth INTEGER NOT NULL DEFAULT 0,
            originalHeight INTEGER NOT NULL DEFAULT 0
          )''');
      },
    );
    return _db!;
  }

  static Future<List<DocumentMeta>> listDocuments() async {
    final db = await database();
    final rows = await db.query('documents', orderBy: 'createdAt DESC');
    final result = <DocumentMeta>[];
    for (final row in rows) {
      final id = row['id'] as int;
      final pages = await pagesOf(id);
      result.add(DocumentMeta(
        id: id,
        title: row['title'] as String,
        createdAt: row['createdAt'] as int,
        scanMode: (row['scanMode'] as String?) ?? 'Document',
        pages: pages,
      ));
    }
    return result;
  }

  static Future<List<StoredPage>> pagesOf(int documentId) async {
    final db = await database();
    final rows = await db.query('scan_pages',
        where: 'documentId = ?', whereArgs: [documentId], orderBy: 'pageIndex');
    return [for (final row in rows) StoredPage.fromRow(row)];
  }

  static Future<DocumentMeta?> readMeta(int id) async {
    final db = await database();
    final rows = await db.query('documents', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final row = rows.first;
    return DocumentMeta(
      id: id,
      title: row['title'] as String,
      createdAt: row['createdAt'] as int,
      scanMode: (row['scanMode'] as String?) ?? 'Document',
      pages: await pagesOf(id),
    );
  }

  /// Saves a document row + pages, and mirrors metadata.json into the document dir.
  static Future<void> saveDocument(DocumentMeta meta) async {
    final db = await database();
    final root = await documentsRoot();
    final dir = Directory(p.join(root.path, meta.id.toString()));
    await dir.create(recursive: true);

    await db.insert('documents', {
      'id': meta.id,
      'title': meta.title,
      'createdAt': meta.createdAt,
      'pageCount': meta.pages.length,
      'thumbnailPath': meta.firstThumbPath ?? '',
      'scanMode': meta.scanMode,
    }, conflictAlgorithm: ConflictAlgorithm.replace);

    await db.delete('scan_pages', where: 'documentId = ?', whereArgs: [meta.id]);
    for (final page in meta.pages) {
      await db.insert('scan_pages', page.toRow(meta.id),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }

    // metadata.json mirror (keeps the original layout contract)
    final json = const JsonEncoder.withIndent('  ').convert(meta.toJson());
    await File(p.join(dir.path, 'metadata.json')).writeAsString(json);
  }

  static Future<void> deleteDocument(int id) async {
    final db = await database();
    await db.delete('scan_pages', where: 'documentId = ?', whereArgs: [id]);
    await db.delete('documents', where: 'id = ?', whereArgs: [id]);
    final root = await documentsRoot();
    final dir = Directory(p.join(root.path, id.toString()));
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  static Future<void> renameDocument(int id, String title) async {
    final db = await database();
    await db.update('documents', {'title': title}, where: 'id = ?', whereArgs: [id]);
    final meta = await readMeta(id);
    if (meta != null) {
      await saveDocument(meta.copyWith(title: title));
    }
  }

  static Future<int> nextPageId() async {
    final db = await database();
    final rows = await db.rawQuery('SELECT MAX(id) as m FROM scan_pages');
    final current = (rows.first['m'] as int?) ?? 0;
    return current + 1;
  }

  static Future<int> nextDocumentId() async {
    final db = await database();
    final rows = await db.rawQuery('SELECT MAX(id) as m FROM documents');
    final current = (rows.first['m'] as int?) ?? 0;
    return current + 1;
  }
}
