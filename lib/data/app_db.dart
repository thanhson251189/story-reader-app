import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/models.dart';

class AppDb {
  Database? _db;

  // Giàn giáo cache chỉ giữ chương mới nhất: cũ hơn bị xóa bớt để dữ liệu
  // không phình to vô hạn. Chương sách trong máy (book:) và chương người dùng
  // tải trước (pinned) không bao giờ bị dọn.
  static const maxCachedChapters = 500;

  // Cache web lâu hơn ngưỡng này coi là nội dung cũ: mở lại thì tải bản mới
  // từ web (lỗi mạng thì vẫn dùng bản cũ, không chặn người đọc).
  static const staleCacheDays = 7;

  Future<Database> get database async => _db ??= await openDatabase(
    p.join(await getDatabasesPath(), 'story_reader.db'),
    version: 6,
    onCreate: (db, v) async {
      await db.execute(
        'CREATE TABLE positions(url TEXT PRIMARY KEY, offset REAL NOT NULL, updated_at INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE chapter_cache(url TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL, next_url TEXT, prev_url TEXT, fetched_at INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0)',
      );
      await db.execute(
        'CREATE TABLE library(story_url TEXT PRIMARY KEY, title TEXT NOT NULL, cover_url TEXT, last_chapter_url TEXT, latest_chapter_url TEXT, latest_chapter_title TEXT, updated_at INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE toc(story_url TEXT NOT NULL, chapter_url TEXT NOT NULL, title TEXT NOT NULL, idx INTEGER NOT NULL, PRIMARY KEY(story_url, chapter_url))',
      );
    },
    onUpgrade: (db, from, to) async {
      if (from < 3) await db.execute('DROP TABLE IF EXISTS local_books');
      if (from < 4) {
        await db.execute(
          'ALTER TABLE library ADD COLUMN latest_chapter_url TEXT',
        );
        await db.execute(
          'ALTER TABLE library ADD COLUMN latest_chapter_title TEXT',
        );
      }
      if (from < 6) {
        // Ghim chương người dùng tải trước trong mục lục: không bị dọn cache.
        await db.execute(
          'ALTER TABLE chapter_cache ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
        );
      }
      if (from < 5) {
        // Nguồn đổi tên miền: viết lại mọi URL cũ để sách cũ + vị trí đọc
        // + cache + TOC + adapter đã cài tiếp tục khớp domain mới.
        const old = 'truyendich.space';
        const neu = 'truyendich.us';
        final like = '%$old%';
        await db.execute(
          "UPDATE OR REPLACE positions SET url = replace(url, '$old', '$neu') WHERE url LIKE '$like'",
        );
        await db.execute(
          "UPDATE OR REPLACE chapter_cache SET url = replace(url, '$old', '$neu'), next_url = replace(next_url, '$old', '$neu'), prev_url = replace(prev_url, '$old', '$neu') WHERE url LIKE '$like' OR next_url LIKE '$like' OR prev_url LIKE '$like'",
        );
        await db.execute(
          "UPDATE OR REPLACE library SET story_url = replace(story_url, '$old', '$neu'), cover_url = replace(cover_url, '$old', '$neu'), last_chapter_url = replace(last_chapter_url, '$old', '$neu'), latest_chapter_url = replace(latest_chapter_url, '$old', '$neu') WHERE story_url LIKE '$like' OR cover_url LIKE '$like' OR last_chapter_url LIKE '$like' OR latest_chapter_url LIKE '$like'",
        );
        await db.execute(
          "UPDATE OR REPLACE toc SET story_url = replace(story_url, '$old', '$neu'), chapter_url = replace(chapter_url, '$old', '$neu') WHERE story_url LIKE '$like' OR chapter_url LIKE '$like'",
        );
        await db.execute(
          "UPDATE settings SET value = replace(value, '$old', '$neu') WHERE key IN ('installedAdapters', 'adapterNames') AND value LIKE '$like'",
        );
      }
    },
  );

  Future<void> savePosition(String url, double offset) async {
    final db = await database;
    await db.insert('positions', {
      'url': url,
      'offset': offset,
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<double?> getPosition(String url) async {
    final db = await database;
    final rows = await db.query(
      'positions',
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    return rows.isEmpty ? null : (rows.first['offset'] as num).toDouble();
  }

  /// Mọi URL chương đã từng mở (bảng positions) — dùng để đánh dấu chương
  /// đã đọc trong mục lục. Mỗi lần mở chương đều lưu vị trí nên coi như đã đọc.
  Future<Set<String>> openedChapterUrls() async {
    final db = await database;
    final rows = await db.query('positions', columns: ['url']);
    return rows.map((r) => r['url'] as String).toSet();
  }

  Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String?> getSetting(String key) async {
    final db = await database;
    final rows = await db.query(
      'settings',
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> cacheChapter(ChapterContent c) => cacheChapters([c]);

  Future<void> cacheChapters(List<ChapterContent> list) async {
    final db = await database;
    final batch = db.batch();
    for (final c in list) {
      // REPLACE xoá hẳn row cũ nên ghim mất; đọc ghim hiện có để giữ lại khi
      // tải lại chương đã ghim (refresh cache cũ, nghe lại...).
      final old = await db.query(
        'chapter_cache',
        columns: ['pinned'],
        where: 'url = ?',
        whereArgs: [c.url],
        limit: 1,
      );
      batch.insert('chapter_cache', {
        'url': c.url,
        'title': c.title,
        'content': jsonEncode(c.paragraphs),
        'next_url': c.nextUrl,
        'prev_url': c.prevUrl,
        'fetched_at': DateTime.now().millisecondsSinceEpoch,
        'pinned': old.isEmpty ? 0 : old.first['pinned'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await pruneChapterCache();
  }

  /// Giữ lại [keep] chương web mới nhất, xóa phần còn lại (theo rowid vì
  /// fetched_at trùng nhau giữa các chương tải cùng lúc thì cứ theo thứ tự).
  /// Chương sách trong máy (book:) và chương đã ghim không bị đụng tới —
  /// sách nhập vào có thể dài hơn hạn mức nhiều lần, chương ghim là lựa chọn
  /// đọc offline rõ ràng của người dùng.
  Future<void> pruneChapterCache({int keep = maxCachedChapters}) async {
    final db = await database;
    await db.execute(
      "DELETE FROM chapter_cache WHERE url NOT LIKE 'book:%' AND pinned = 0 "
      'AND rowid NOT IN '
      "(SELECT rowid FROM chapter_cache WHERE url NOT LIKE 'book:%' "
      'AND pinned = 0 '
      'ORDER BY fetched_at DESC LIMIT ?)',
      [keep],
    );
  }

  /// Ghim một chương web: không bị dọn cache, không bị xoá khi "Xoá dữ liệu
  /// tải sẵn". Đặt khi tải trước trong mục lục.
  Future<void> pinChapter(String url) async {
    final db = await database;
    await db.update(
      'chapter_cache',
      {'pinned': 1},
      where: 'url = ?',
      whereArgs: [url],
    );
  }

  /// Số chương web đang được ghim.
  Future<int> pinnedWebCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM chapter_cache WHERE url NOT LIKE 'book:%' AND pinned = 1",
          ),
        ) ??
        0;
  }

  Future<int?> chapterFetchedAt(String url) async {
    final db = await database;
    final rows = await db.query(
      'chapter_cache',
      columns: ['fetched_at'],
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['fetched_at'] as int;
  }

  /// Số chương web đang được lưu tạm (không tính sách trong máy).
  Future<int> webCacheCount() async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT COUNT(*) FROM chapter_cache WHERE url NOT LIKE 'book:%'",
          ),
        ) ??
        0;
  }

  /// Xóa cache chương web để trả lại dung lượng; chương đã ghim và sách
  /// trong máy giữ nguyên — ghim là lựa chọn giữ rõ ràng của người dùng,
  /// sách xoá mất thì phải nhập lại file.
  Future<void> clearWebCache() async {
    final db = await database;
    await db.delete(
      'chapter_cache',
      where: "url NOT LIKE 'book:%' AND pinned = 0",
    );
  }

  Future<ChapterContent?> getCachedChapter(String url) async {
    final db = await database;
    final rows = await db.query(
      'chapter_cache',
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return ChapterContent(
      url: r['url'] as String,
      title: r['title'] as String,
      paragraphs: List<String>.from(jsonDecode(r['content'] as String) as List),
      nextUrl: r['next_url'] as String?,
      prevUrl: r['prev_url'] as String?,
    );
  }

  Future<Set<String>> getCachedChapterUrls() async {
    final db = await database;
    final rows = await db.query('chapter_cache', columns: ['url']);
    return rows.map((r) => r['url'] as String).toSet();
  }

  Future<void> upsertLibrary({
    required String storyUrl,
    required String title,
    String? coverUrl,
    String? lastChapterUrl,
  }) async {
    final db = await database;
    // REPLACE xoá hẳn dòng cũ rồi ghi dòng mới: 2 ô "chương mới nhất" và bìa
    // không nằm trong dòng mới sẽ thành NULL — mất badge "Mới" khi làm mới
    // mục lục hay thêm lại truyện đã có. Đọc trước để giữ lại.
    final old = await db.query(
      'library',
      columns: ['latest_chapter_url', 'latest_chapter_title', 'cover_url'],
      where: 'story_url = ?',
      whereArgs: [storyUrl],
      limit: 1,
    );
    await db.insert('library', {
      'story_url': storyUrl,
      'title': title,
      'cover_url': coverUrl ?? (old.isEmpty ? null : old.first['cover_url']),
      'last_chapter_url': lastChapterUrl,
      if (old.isNotEmpty) ...{
        'latest_chapter_url': old.first['latest_chapter_url'],
        'latest_chapter_title': old.first['latest_chapter_title'],
      },
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getLibrary() async {
    final db = await database;
    return db.query('library', orderBy: 'updated_at DESC');
  }

  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {
    final db = await database;
    await db.update(
      'library',
      {
        'last_chapter_url': chapterUrl,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'story_url = ?',
      whereArgs: [storyUrl],
    );
  }

  Future<void> setLatestChapter(
    String storyUrl,
    String url,
    String title,
  ) async {
    final db = await database;
    await db.update(
      'library',
      {'latest_chapter_url': url, 'latest_chapter_title': title},
      where: 'story_url = ?',
      whereArgs: [storyUrl],
    );
  }

  Future<void> removeFromLibrary(String storyUrl) async {
    final db = await database;
    await db.delete('library', where: 'story_url = ?', whereArgs: [storyUrl]);
    await db.delete('toc', where: 'story_url = ?', whereArgs: [storyUrl]);
    if (storyUrl.startsWith('book:')) {
      await db.delete(
        'chapter_cache',
        where: 'url LIKE ?',
        whereArgs: ['$storyUrl:%'],
      );
    }
  }

  Future<void> saveToc(String storyUrl, List<ChapterRef> chapters) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('toc', where: 'story_url = ?', whereArgs: [storyUrl]);
      final batch = txn.batch();
      for (var i = 0; i < chapters.length; i++) {
        batch.insert('toc', {
          'story_url': storyUrl,
          'chapter_url': chapters[i].url,
          'title': chapters[i].title,
          'idx': i,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<ChapterRef>> getToc(String storyUrl) async {
    final db = await database;
    final rows = await db.query(
      'toc',
      where: 'story_url = ?',
      whereArgs: [storyUrl],
      orderBy: 'idx ASC',
    );
    return rows
        .map(
          (r) => ChapterRef(
            title: r['title'] as String,
            url: r['chapter_url'] as String,
          ),
        )
        .toList();
  }

  /// Ghi kết quả nạp một truyện: mục lục + (tuỳ chọn) đưa vào thư viện với
  /// chương đang đọc. Dùng chung cho nút "thêm vào thư viện" ở màn đọc, lần
  /// đầu nạp mục lục và kiểm tra chương mới — một quy tắc lưu duy nhất để
  /// không lệch nhau. Không truyền [lastChapterUrl] khi chỉ muốn làm mới mục
  /// lục mà không đụng dòng "đang đọc" trong thư viện.
  Future<void> saveStoryInfo(
    String storyUrl,
    NovelInfo info, {
    String? lastChapterUrl,
  }) async {
    await saveToc(storyUrl, info.chapters);
    if (lastChapterUrl != null) {
      await upsertLibrary(
        storyUrl: storyUrl,
        title: info.title,
        coverUrl: info.coverUrl,
        lastChapterUrl: lastChapterUrl,
      );
    }
  }
}
