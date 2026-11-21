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

  static const backupVersion = 1;

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

    for (final r in (data['settings'] as List? ?? [])) {
      final m = Map<String, dynamic>.from(r as Map);
      if (m['key'] is String && m['value'] != null) {
        await db.setSetting(m['key'] as String, '${m['value']}');
      }
    }

    for (final r in (data['library'] as List? ?? [])) {
      await d.insert(
        'library',
        Map<String, dynamic>.from(r as Map),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    final batch = d.batch();
    for (final r in (data['toc'] as List? ?? [])) {
      batch.insert(
        'toc',
        Map<String, dynamic>.from(r as Map),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);

    for (final r in (data['positions'] as List? ?? [])) {
      await d.insert(
        'positions',
        Map<String, dynamic>.from(r as Map),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

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
