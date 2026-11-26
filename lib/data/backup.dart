import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../core/models.dart';
import 'app_db.dart';

/// Sao lưu / phục hồi dữ liệu người dùng ra một file JSON: thư viện, mục
/// lục, vị trí đọc, cài đặt và nội dung sách đã nhập trong máy. Cache chương
/// web không sao lưu vì tải lại được; sách đã nhập thì phải có trong file —
/// mất file gốc là không đọc lại được.
class DataBackup {
  final AppDb db;
  DataBackup(this.db);

  // v2 (app 1.0.73): bảng có cột norm_*. Bản cũ từ chối file v2 thay vì
  // chèn cột lạ vào bảng cũ; bản mới vẫn đọc được file v1 và tự tính norm.
  static const backupVersion = 2;

  Future<Map<String, dynamic>> export() async {
    final d = await db.database;
    return {
      'app': 'story-reader',
      'backupVersion': backupVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'settings': await d.query('settings'),
      'library': await d.query('library'),
      'toc': await d.query('toc'),
      'positions': await d.query('positions'),
      'bookmarks': await d.query('bookmarks'),
      'bookCache': await d.query('chapter_cache', where: "url LIKE 'book:%'"),
    };
  }

  /// Ghép dữ liệu từ file vào dữ liệu hiện có (không xoá phần khác).
  /// Bản cài nguồn truyện đưa vào settings sẽ được nạp lại bằng
  /// SourceRegistry.restoreInstalled bởi nơi gọi hàm này.
  Future<void> import(Map<String, dynamic> data) async {
    if (data['app'] != 'story-reader') {
      throw FormatException('Đây không phải file sao lưu của Story Reader');
    }
    final v = data['backupVersion'];
    if (v is! int || v > backupVersion) {
      throw FormatException(
        'File sao lưu từ bản mới hơn, app này chưa đọc được',
      );
    }
    final d = await db.database;

    // Gom mọi bảng vào một batch: khôi phục vài nghìn vị trí đọc mà insert
    // từng dòng thì mỗi dòng một lần ghi đĩa, chậm và dễ nghẽn UI.
    final batch = d.batch();
    for (final r in (data['settings'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      if (m['key'] is String && m['value'] != null) {
        batch.insert('settings', {
          'key': m['key'] as String,
          'value': '${m['value']}',
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }

    for (final r in (data['library'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      final story = m['story_url'];
      if (story is String) m['norm_story'] = normalizeChapterUrl(story);
      batch.insert(
        'library',
        m,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    for (final r in (data['toc'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      final story = m['story_url'];
      final chapter = m['chapter_url'];
      if (story is String) m['norm_story'] = normalizeChapterUrl(story);
      if (chapter is String) m['norm_url'] = normalizeChapterUrl(chapter);
      batch.insert(
        'toc',
        m,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    for (final r in (data['positions'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      final url = m['url'];
      if (url is String) m['norm_url'] = normalizeChapterUrl(url);
      batch.insert(
        'positions',
        m,
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);

    // Đánh dấu đoạn: bỏ id, dedupe theo (story, chapter, para) đã có UNIQUE —
    // trùng với đánh dấu hiện có thì bỏ qua, không đè created_at mới hơn.
    final batchBookmarks = d.batch();
    for (final r in (data['bookmarks'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map)..remove('id');
      final story = m['story_url'];
      if (story is String) m['norm_story'] = normalizeChapterUrl(story);
      batchBookmarks.insert(
        'bookmarks',
        m,
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }
    await batchBookmarks.commit(noResult: true);

    final chapters = <ChapterContent>[];
    for (final r in (data['bookCache'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      final url = m['url'] as String?;
      final content = m['content'] as String?;
      if (url == null || content == null) continue;
      chapters.add(
        ChapterContent(
          url: url,
          title: m['title'] as String? ?? '',
          paragraphs: List<String>.from(jsonDecode(content) as List),
          nextUrl: m['next_url'] as String?,
          prevUrl: m['prev_url'] as String?,
        ),
      );
    }
    await db.cacheChapters(chapters);
  }
}
