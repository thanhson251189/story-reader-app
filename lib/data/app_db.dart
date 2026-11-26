import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/models.dart';

/// Một cụm từ người dùng dạy thay. [storyUrl] null = mọi truyện; có giá trị =
/// chỉ truyện đó. So khớp phạm vi bỏ khác biệt vô hại của link (slash cuối,
/// hoa thường) — cùng quy tắc với link chương, không phải đoán truyện khác.
class WordFix {
  final String from;
  final String to;
  final String? storyUrl;

  const WordFix(this.from, this.to, {this.storyUrl});

  bool sameScope(String? other) => sameChapterUrl(storyUrl, other);

  @override
  bool operator ==(Object other) =>
      other is WordFix &&
      from == other.from &&
      to == other.to &&
      storyUrl == other.storyUrl;

  @override
  int get hashCode => Object.hash(from, to, storyUrl);
}

class AppDb {
  Database? _db;

  // Tên file DB: mặc định của app; test truyền tên riêng để các file test
  // chạy song song trong isolate khác nhau không xoá/lẫn DB của nhau.
  final String fileName;
  AppDb({this.fileName = 'story_reader.db'});

  // Giàn giáo cache chỉ giữ chương mới nhất: cũ hơn bị xóa bớt để dữ liệu
  // không phình to vô hạn. Chương sách trong máy (book:) và chương người dùng
  // tải trước (pinned) không bao giờ bị dọn.
  static const maxCachedChapters = 500;

  // Cache web lâu hơn ngưỡng này coi là nội dung cũ: mở lại thì tải bản mới
  // từ web (lỗi mạng thì vẫn dùng bản cũ, không chặn người đọc).
  static const staleCacheDays = 7;

  // Bảng đánh dấu đoạn (bookmark): mỗi dòng = 1 đoạn được người dùng ghim
  // trong truyện đang đọc. UNIQUE để toggle và phục hồi sao lưu không sinh
  // dòng trùng.
  static const _createBookmarksSql =
      'CREATE TABLE bookmarks(id INTEGER PRIMARY KEY AUTOINCREMENT, story_url TEXT NOT NULL, chapter_url TEXT NOT NULL, chapter_title TEXT NOT NULL, para_index INTEGER NOT NULL, snippet TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(story_url, chapter_url, para_index))';

  Future<Database> get database async => _db ??= await openDatabase(
    p.join(await getDatabasesPath(), fileName),
    version: 8,
    onCreate: (db, v) async {
      await db.execute(
        'CREATE TABLE positions(url TEXT PRIMARY KEY, offset REAL NOT NULL, updated_at INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE chapter_cache(url TEXT PRIMARY KEY, title TEXT NOT NULL, content TEXT NOT NULL, next_url TEXT, prev_url TEXT, fetched_at INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, opened_at INTEGER NOT NULL DEFAULT 0)',
      );
      await db.execute(
        'CREATE TABLE library(story_url TEXT PRIMARY KEY, title TEXT NOT NULL, cover_url TEXT, last_chapter_url TEXT, latest_chapter_url TEXT, latest_chapter_title TEXT, updated_at INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE toc(story_url TEXT NOT NULL, chapter_url TEXT NOT NULL, title TEXT NOT NULL, idx INTEGER NOT NULL, PRIMARY KEY(story_url, chapter_url))',
      );
      await db.execute(_createBookmarksSql);
    },
    onUpgrade: (db, from, to) async {
      if (from < 7) await db.execute(_createBookmarksSql);
      if (from < 8) {
        // opened_at = lần mở/ghi gần nhất, để dọn cache không xóa chương vừa đọc.
        // fetched_at giữ nghĩa "lần tải từ web" — mở lại không được làm mới mốc này.
        await db.execute(
          'ALTER TABLE chapter_cache ADD COLUMN opened_at INTEGER NOT NULL DEFAULT 0',
        );
      }
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
    final exact = await db.query(
      'positions',
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (exact.isNotEmpty) return (exact.first['offset'] as num).toDouble();
    // Link mục lục và location.href hay lệch slash cuối / fragment / http.
    // Vị trí được ghi theo link sau khi mở; lần mở sau dùng link mục lục.
    final stored = await _positionByNormalizedUrl(db, url);
    return stored == null ? null : (stored['offset'] as num).toDouble();
  }

  Future<Map<String, Object?>?> _positionByNormalizedUrl(
    Database db,
    String url,
  ) async {
    if (url.startsWith('book:')) return null;
    final want = normalizeChapterUrl(url);
    final rows = await db.query(
      'positions',
      columns: ['url', 'offset', 'updated_at'],
    );
    Map<String, Object?>? best;
    var bestAt = -1;
    for (final r in rows) {
      final stored = r['url'] as String;
      if (stored.startsWith('book:')) continue;
      if (normalizeChapterUrl(stored) != want) continue;
      final at = r['updated_at'] as int? ?? 0;
      if (at >= bestAt) {
        bestAt = at;
        best = r;
      }
    }
    return best;
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

  Future<void> cacheChapter(ChapterContent c, {bool touchFetchedAt = true}) =>
      cacheChapters([c], touchFetchedAt: touchFetchedAt);

  // Giới hạn số biến trong một mệnh đề IN (SQLite máy cũ còn giới hạn 999).
  static const _pinQueryBatch = 500;

  Future<void> cacheChapters(
    List<ChapterContent> list, {
    bool touchFetchedAt = true,
  }) async {
    if (list.isEmpty) return;
    final db = await database;
    // REPLACE xoá hẳn row cũ nên ghim mất; đọc ghim hiện có để giữ lại khi
    // ghi đè chương đã ghim (refresh cache cũ, nghe lại...). Đọc MỘT lượt
    // thay vì từng chương: nhập sách dài vài nghìn chương mà query riêng từng
    // cái là nhập chậm thêm nhiều giây trên máy yếu.
    final pinnedUrls = <String>{};
    final fetchedAt = <String, int>{};
    final urls = list.map((c) => c.url).toList();
    for (var i = 0; i < urls.length; i += _pinQueryBatch) {
      final end = i + _pinQueryBatch > urls.length
          ? urls.length
          : i + _pinQueryBatch;
      final chunk = urls.sublist(i, end);
      final ph = List.filled(chunk.length, '?').join(',');
      final rows = await db.query(
        'chapter_cache',
        columns: ['url', 'pinned', 'fetched_at'],
        where: 'url IN ($ph)',
        whereArgs: chunk,
      );
      for (final r in rows) {
        final url = r['url'] as String;
        if (r['pinned'] == 1) pinnedUrls.add(url);
        final at = r['fetched_at'];
        if (at is int) fetchedAt[url] = at;
      }
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final batch = db.batch();
    for (final c in list) {
      // touchFetchedAt false: mở lại bản đã lưu, không tính là vừa tải từ web.
      // fetched_at giữ nguyên thì lần mở sau 7 ngày vẫn được làm mới.
      batch.insert('chapter_cache', {
        'url': c.url,
        'title': c.title,
        'content': jsonEncode(c.paragraphs),
        'next_url': c.nextUrl,
        'prev_url': c.prevUrl,
        'fetched_at': touchFetchedAt ? now : (fetchedAt[c.url] ?? now),
        'pinned': pinnedUrls.contains(c.url) ? 1 : 0,
        'opened_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
    await pruneChapterCache();
  }

  /// Giữ lại [keep] chương web mới nhất, xóa phần còn lại. "Mới" tính theo lần
  /// mở hoặc lần tải, lấy mốc muộn hơn — chương vừa đọc không bị dọn chỉ vì
  /// lần tải từ web đã cũ. fetched_at trùng nhau thì theo thứ tự row.
  /// Chương sách trong máy (book:) và chương đã ghim không bị đụng tới.
  Future<void> pruneChapterCache({int keep = maxCachedChapters}) async {
    final db = await database;
    await db.execute(
      "DELETE FROM chapter_cache WHERE url NOT LIKE 'book:%' AND pinned = 0 "
      'AND rowid NOT IN '
      "(SELECT rowid FROM chapter_cache WHERE url NOT LIKE 'book:%' "
      'AND pinned = 0 '
      'ORDER BY MAX(fetched_at, opened_at) DESC LIMIT ?)',
      [keep],
    );
  }

  /// Ghim một chương web: không bị dọn cache, không bị xoá khi "Xoá dữ liệu
  /// tải sẵn". Đặt khi tải trước trong mục lục.
  /// Khớp cả link lệch nhẹ (slash cuối, fragment): hàng cache ghi theo
  /// location.href, còn mục lục ghim theo link đã bấm — ghim đúng key thì
  /// cập nhật 0 dòng và chương bị dọn mất.
  Future<void> pinChapter(String url) async {
    final db = await database;
    final key = await _cachedUrlKey(db, url);
    if (key == null) return;
    await db.update(
      'chapter_cache',
      {'pinned': 1},
      where: 'url = ?',
      whereArgs: [key],
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
    final key = await _cachedUrlKey(db, url);
    if (key == null) return null;
    final rows = await db.query(
      'chapter_cache',
      columns: ['fetched_at'],
      where: 'url = ?',
      whereArgs: [key],
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

  /// Link chương thuộc một truyện: lấy từ mục lục đã lưu cộng các dòng cache
  /// khớp tiền tố/đã chuẩn hoá. Nguồn CMS có thể đặt link chương ngoài tiền
  /// tố trang truyện nên phải quét cache, không chỉ `LIKE 'storyUrl%'`.
  Future<Set<String>> _storyChapterUrls(Database db, String storyUrl) async {
    final out = <String>{};
    final keys = await _storyKeys(storyUrl);
    for (final key in keys) {
      final toc = await db.query(
        'toc',
        columns: ['chapter_url'],
        where: 'story_url = ?',
        whereArgs: [key],
      );
      for (final r in toc) {
        out.add(r['chapter_url'] as String);
      }
      if (key.startsWith('book:')) continue;
      final cached = await db.query('chapter_cache', columns: ['url']);
      for (final r in cached) {
        final url = r['url'] as String;
        if (sameChapterUrl(url, key) || _chapterOfStory(url, key)) {
          out.add(url);
        }
      }
    }
    return out;
  }

  /// Số chương web của truyện đang nằm trong máy (kể cả chương đã ghim).
  Future<int> cachedChapterCountForStory(String storyUrl) async {
    final db = await database;
    final urls = (await _storyChapterUrls(
      db,
      storyUrl,
    )).where((u) => !u.startsWith('book:')).toList();
    var count = 0;
    for (var i = 0; i < urls.length; i += _pinQueryBatch) {
      final end = i + _pinQueryBatch > urls.length
          ? urls.length
          : i + _pinQueryBatch;
      final chunk = urls.sublist(i, end);
      final ph = List.filled(chunk.length, '?').join(',');
      count +=
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM chapter_cache WHERE url IN ($ph)',
              chunk,
            ),
          ) ??
          0;
    }
    return count;
  }

  /// Xoá chương web đã tải của RIÊNG một truyện để trả dung lượng. Chương
  /// đã ghim cũng bị xoá vì đây là lựa chọn rõ ràng của người dùng; sách
  /// trong máy không bao giờ bị đụng. Trả về số dòng đã xoá.
  Future<int> clearCachedChaptersForStory(String storyUrl) async {
    final db = await database;
    final urls = (await _storyChapterUrls(
      db,
      storyUrl,
    )).where((u) => !u.startsWith('book:')).toList();
    var deleted = 0;
    for (var i = 0; i < urls.length; i += _pinQueryBatch) {
      final end = i + _pinQueryBatch > urls.length
          ? urls.length
          : i + _pinQueryBatch;
      final chunk = urls.sublist(i, end);
      final ph = List.filled(chunk.length, '?').join(',');
      deleted += await db.delete(
        'chapter_cache',
        where: 'url IN ($ph)',
        whereArgs: chunk,
      );
    }
    return deleted;
  }

  /// Key thật trong cache. Đúng nguyên văn thì dùng luôn; không thì khớp link
  /// đã chuẩn hóa (bỏ slash cuối, fragment, hoa thường host, http/https).
  Future<String?> _cachedUrlKey(Database db, String url) async {
    final exact = await db.query(
      'chapter_cache',
      columns: ['url'],
      where: 'url = ?',
      whereArgs: [url],
      limit: 1,
    );
    if (exact.isNotEmpty) return exact.first['url'] as String;
    if (url.startsWith('book:')) return null;
    final want = normalizeChapterUrl(url);
    final rows = await db.query('chapter_cache', columns: ['url']);
    for (final r in rows) {
      final stored = r['url'] as String;
      if (stored.startsWith('book:')) continue;
      if (normalizeChapterUrl(stored) == want) return stored;
    }
    return null;
  }

  Future<ChapterContent?> getCachedChapter(String url) async {
    final db = await database;
    final key = await _cachedUrlKey(db, url);
    if (key == null) return null;
    final rows = await db.query(
      'chapter_cache',
      where: 'url = ?',
      whereArgs: [key],
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

  /// Khóa truyện đã lưu mà cùng một truyện với [storyUrl]. Khóa trong thư viện
  /// đứng trước để ghi mới không tách đôi truyện chỉ vì lệch slash hoặc http.
  /// Chưa có dòng nào thì trả về chính [storyUrl] để tạo mới.
  Future<List<String>> _storyKeys(String storyUrl) async {
    if (storyUrl.startsWith('book:')) return [storyUrl];
    final db = await database;
    final found = <String>[];
    void add(String? stored) {
      if (stored == null || stored.isEmpty || found.contains(stored)) return;
      if (stored == storyUrl || sameChapterUrl(stored, storyUrl)) {
        found.add(stored);
      }
    }

    for (final table in const ['library', 'toc', 'bookmarks']) {
      final rows = await db.query(
        table,
        columns: ['story_url'],
        distinct: true,
      );
      for (final r in rows) {
        add(r['story_url'] as String?);
      }
    }
    if (found.isEmpty) return [storyUrl];
    final lib = await db.query('library', columns: ['story_url']);
    for (final r in lib) {
      final s = r['story_url'] as String?;
      if (s != null && found.contains(s)) {
        return [s, ...found.where((k) => k != s)];
      }
    }
    if (found.contains(storyUrl)) {
      return [storyUrl, ...found.where((k) => k != storyUrl)];
    }
    return found;
  }

  bool _chapterOfStory(String chapterUrl, String storyUrl) {
    if (storyUrl.startsWith('book:')) {
      return chapterUrl == storyUrl || chapterUrl.startsWith('$storyUrl:');
    }
    if (sameChapterUrl(chapterUrl, storyUrl)) return true;
    final base = storyUrl.endsWith('/') ? storyUrl : '$storyUrl/';
    if (chapterUrl.startsWith(base)) return true;
    final nb = normalizeChapterUrl(storyUrl);
    final nc = normalizeChapterUrl(chapterUrl);
    return nc == nb || nc.startsWith('$nb/');
  }

  Future<void> upsertLibrary({
    required String storyUrl,
    required String title,
    String? coverUrl,
    String? lastChapterUrl,
  }) async {
    final db = await database;
    final keys = await _storyKeys(storyUrl);
    final key = keys.first;
    // REPLACE xoá hẳn dòng cũ rồi ghi dòng mới: 2 ô "chương mới nhất" và bìa
    // không nằm trong dòng mới sẽ thành NULL — mất badge "Mới" khi làm mới
    // mục lục hay thêm lại truyện đã có. Đọc trước để giữ lại.
    final old = await db.query(
      'library',
      columns: ['latest_chapter_url', 'latest_chapter_title', 'cover_url'],
      where: 'story_url = ?',
      whereArgs: [key],
      limit: 1,
    );
    await db.insert('library', {
      'story_url': key,
      'title': title,
      'cover_url': coverUrl ?? (old.isEmpty ? null : old.first['cover_url']),
      'last_chapter_url': lastChapterUrl,
      if (old.isNotEmpty) ...{
        'latest_chapter_url': old.first['latest_chapter_url'],
        'latest_chapter_title': old.first['latest_chapter_title'],
      },
      'updated_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    for (final k in keys) {
      if (k == key) continue;
      await db.delete('library', where: 'story_url = ?', whereArgs: [k]);
    }
  }

  Future<List<Map<String, dynamic>>> getLibrary() async {
    final db = await database;
    return db.query('library', orderBy: 'updated_at DESC');
  }

  /// Truyện đã nằm trong thư viện chưa. So link đã chuẩn hóa vì cùng một
  /// truyện có thể lệch slash cuối hoặc hoa thường tên miền.
  Future<bool> isInLibrary(String storyUrl) async {
    final rows = await getLibrary();
    for (final r in rows) {
      final stored = r['story_url'] as String? ?? '';
      if (sameChapterUrl(stored, storyUrl)) return true;
    }
    return false;
  }

  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {
    final db = await database;
    final key = (await _storyKeys(storyUrl)).first;
    await db.update(
      'library',
      {
        'last_chapter_url': chapterUrl,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'story_url = ?',
      whereArgs: [key],
    );
  }

  Future<void> setLatestChapter(
    String storyUrl,
    String url,
    String title,
  ) async {
    final db = await database;
    final key = (await _storyKeys(storyUrl)).first;
    await db.update(
      'library',
      {'latest_chapter_url': url, 'latest_chapter_title': title},
      where: 'story_url = ?',
      whereArgs: [key],
    );
  }

  Future<void> removeFromLibrary(String storyUrl) async {
    final db = await database;
    final keys = await _storyKeys(storyUrl);
    final chapterUrls = <String>[];
    for (final key in keys) {
      final rows = await db.query(
        'toc',
        columns: ['chapter_url'],
        where: 'story_url = ?',
        whereArgs: [key],
      );
      chapterUrls.addAll(rows.map((r) => r['chapter_url'] as String));
    }
    final positions = await db.query('positions', columns: ['url']);
    for (final r in positions) {
      final url = r['url'] as String;
      final inToc = chapterUrls.any((c) => c == url || sameChapterUrl(c, url));
      final inStory = keys.any((k) => _chapterOfStory(url, k));
      if (inToc || inStory) {
        await db.delete('positions', where: 'url = ?', whereArgs: [url]);
      }
    }
    for (final key in keys) {
      await db.delete('library', where: 'story_url = ?', whereArgs: [key]);
      await db.delete('toc', where: 'story_url = ?', whereArgs: [key]);
      await db.delete('bookmarks', where: 'story_url = ?', whereArgs: [key]);
      if (key.startsWith('book:')) {
        await db.delete(
          'chapter_cache',
          where: 'url LIKE ?',
          whereArgs: ['$key:%'],
        );
      }
    }
  }

  /// Đổi truyện trong thư viện sang nguồn khác, giữ vị trí theo chương đã
  /// map. Mục lục cũ, vị trí đọc cũ và đánh dấu cũ được GIỮ trong DB để còn
  /// quay lại nguồn cũ; chỉ dòng thư viện cũ bị bỏ để không hiện trùng.
  Future<void> switchLibrarySource({
    required String oldStoryUrl,
    required String newStoryUrl,
    required String title,
    String? coverUrl,
    required String chapterUrl,
    required List<ChapterRef> toc,
  }) async {
    await saveToc(newStoryUrl, toc);
    await upsertLibrary(
      storyUrl: newStoryUrl,
      title: title,
      coverUrl: coverUrl,
      lastChapterUrl: chapterUrl,
    );
    final db = await database;
    for (final key in await _storyKeys(oldStoryUrl)) {
      if (sameChapterUrl(key, newStoryUrl)) continue;
      await db.delete('library', where: 'story_url = ?', whereArgs: [key]);
    }
    // Chương mới chưa có vị trí cuộn: đặt 0 để mở từ đầu chương thay vì
    // dính vị trí của chương cùng số ở nguồn cũ (nếu có).
    await savePosition(chapterUrl, 0);
    await setSetting('lastUrl', chapterUrl);
    await setSetting('lastTitle', title);
    // Sửa từ "chỉ truyện này" là công sức người dùng dạy cho đúng bản dịch;
    // chép sang link nguồn mới để không phải nhập lại.
    final fixes = await getWordFixes();
    final copied = <WordFix>[];
    for (final f in fixes) {
      final from = f.storyUrl;
      if (from == null || !f.sameScope(oldStoryUrl)) continue;
      final exists = fixes.any(
        (x) =>
            x.storyUrl != null && x.sameScope(newStoryUrl) && x.from == f.from,
      );
      if (!exists) copied.add(WordFix(f.from, f.to, storyUrl: newStoryUrl));
    }
    if (copied.isNotEmpty) await setWordFixes([...fixes, ...copied]);
  }

  // ---- Đánh dấu đoạn (bookmark) ----

  /// Toggle đánh dấu một đoạn: đang có thì XOÁ, chưa có thì THÊM. Trả về
  /// true nếu SAU lệnh gọi đoạn đang được đánh dấu.
  Future<bool> toggleBookmark({
    required String storyUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int paraIndex,
    required String snippet,
  }) async {
    final db = await database;
    final keys = await _storyKeys(storyUrl);
    final rows = await db.query(
      'bookmarks',
      where: 'para_index = ?',
      whereArgs: [paraIndex],
    );
    for (final r in rows) {
      final story = r['story_url'] as String? ?? '';
      final chapter = r['chapter_url'] as String? ?? '';
      final sameStory = keys.contains(story) || sameChapterUrl(story, storyUrl);
      if (!sameStory) continue;
      if (chapter != chapterUrl && !sameChapterUrl(chapter, chapterUrl)) {
        continue;
      }
      await db.delete('bookmarks', where: 'id = ?', whereArgs: [r['id']]);
      return false;
    }
    await db.insert('bookmarks', {
      'story_url': keys.first,
      'chapter_url': chapterUrl,
      'chapter_title': chapterTitle,
      'para_index': paraIndex,
      'snippet': snippet,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    return true;
  }

  /// Danh sách đánh dấu của một truyện, mới nhất lên đầu. Gộp cả dòng lưu dưới
  /// link lệch nhẹ của cùng truyện.
  Future<List<Map<String, dynamic>>> getBookmarks(String storyUrl) async {
    final db = await database;
    final keys = await _storyKeys(storyUrl);
    final merged = <Map<String, dynamic>>[];
    for (final key in keys) {
      merged.addAll(
        await db.query('bookmarks', where: 'story_url = ?', whereArgs: [key]),
      );
    }
    merged.sort((a, b) {
      final at = (a['created_at'] as int? ?? 0).compareTo(
        b['created_at'] as int? ?? 0,
      );
      if (at != 0) return -at;
      return ((a['id'] as int? ?? 0).compareTo(b['id'] as int? ?? 0)) * -1;
    });
    return merged;
  }

  Future<void> removeBookmark(int id) async {
    final db = await database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> saveToc(String storyUrl, List<ChapterRef> chapters) async {
    final db = await database;
    final keys = await _storyKeys(storyUrl);
    final key = keys.first;
    await db.transaction((txn) async {
      for (final k in keys) {
        await txn.delete('toc', where: 'story_url = ?', whereArgs: [k]);
      }
      final batch = txn.batch();
      for (var i = 0; i < chapters.length; i++) {
        batch.insert('toc', {
          'story_url': key,
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
    final keys = await _storyKeys(storyUrl);
    List<ChapterRef> best = [];
    for (final key in keys) {
      final rows = await db.query(
        'toc',
        where: 'story_url = ?',
        whereArgs: [key],
        orderBy: 'idx ASC',
      );
      final list = rows
          .map(
            (r) => ChapterRef(
              title: r['title'] as String,
              url: r['chapter_url'] as String,
            ),
          )
          .toList();
      if (list.length > best.length) best = list;
    }
    return best;
  }

  /// Chương trước/sau của một URL chương suy từ mục lục đã lưu. Dùng làm dự
  /// phòng cho nguồn không có nút prev/next trên trang chương (trang có nút
  /// thì link trên trang luôn thắng). Khớp chương theo URL đã chuẩn hóa để
  /// không lệch một ký tự (slash cuối, fragment) mà âm thầm vô hiệu.
  Future<(String?, String?)> chapterNeighbors(String chapterUrl) async {
    final db = await database;
    final want = normalizeChapterUrl(chapterUrl);
    final rows = await db.query(
      'toc',
      columns: ['story_url', 'chapter_url', 'idx'],
    );
    Map<String, dynamic>? hit;
    for (final r in rows) {
      if (normalizeChapterUrl(r['chapter_url'] as String) == want) {
        hit = r;
        break;
      }
    }
    if (hit == null) return (null, null);
    final storyUrl = hit['story_url'] as String;
    final idx = hit['idx'] as int;
    Future<String?> at(int i) async {
      final r = await db.query(
        'toc',
        where: 'story_url = ? AND idx = ?',
        whereArgs: [storyUrl, i],
        limit: 1,
      );
      return r.isEmpty ? null : r.first['chapter_url'] as String;
    }

    return (await at(idx - 1), await at(idx + 1));
  }

  /// Bổ sung chương trước/sau thiếu cho nội dung chương, suy từ mục lục đã
  /// lưu. Dùng chung cho MỌI đường tải (màn đọc, nghe đọc, tải trước): nguồn
  /// không có nút prev/next trên trang thì chỉ đường này biết chương kế là
  /// gì — thiếu ở đường nào thì tính năng "nghe tự sang chương kế" chết ở
  /// đường đó. Chương đã đủ thông tin trả nguyên vẹn (link trên trang thắng).
  Future<ChapterContent> fillNav(ChapterContent c) async {
    if (c.nextUrl != null && c.prevUrl != null) return c;
    try {
      final (prev, next) = await chapterNeighbors(c.url);
      if (prev == null && next == null) return c;
      return ChapterContent(
        url: c.url,
        title: c.title,
        paragraphs: c.paragraphs,
        nextUrl: c.nextUrl ?? next,
        prevUrl: c.prevUrl ?? prev,
      );
    } catch (_) {
      return c;
    }
  }

  /// Ghi mục lục chỉ khi bản mới đủ trang và không ngắn hơn bản đang lưu.
  /// Dùng cho kiểm tra ngầm và mở từ tìm kiếm: bản thiếu không được đè bản đủ.
  /// Không đụng thư viện. Trả về true nếu đã ghi.
  Future<bool> saveTocUnlessShorter(String storyUrl, NovelInfo info) async {
    if (!info.tocComplete || info.chapters.isEmpty) return false;
    final existing = await getToc(storyUrl);
    if (existing.length > info.chapters.length) return false;
    await saveToc(storyUrl, info.chapters);
    return true;
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
    // Mục lục thiếu trang không được xoá danh sách đang có. Làm mới tay khi
    // tải đủ vẫn ghi đè, kể cả khi trang web bỏ bớt chương.
    if (info.tocComplete) {
      await saveToc(storyUrl, info.chapters);
    }
    if (lastChapterUrl != null) {
      await upsertLibrary(
        storyUrl: storyUrl,
        title: info.title,
        coverUrl: info.coverUrl,
        lastChapterUrl: lastChapterUrl,
      );
    }
  }

  // ---- Từ/cụm từ sửa lỗi người dùng dạy ----

  /// Key settings chứa danh sách sửa từ. Mục cũ là 2 phần tử
  /// ["cụm từ sai", "thay bằng"] = mọi truyện — giữ nguyên dạng đó để bản app
  /// cũ và bản sao lưu cũ vẫn đọc được. Mục chỉ một truyện thêm URL truyện
  /// ở phần tử thứ ba; bản app cũ bỏ qua phần tử dài hơn 2, không làm mất
  /// mục chung. Để trong bảng settings thì sao lưu/phục hồi tự mang theo.
  static const wordFixesKey = 'wordReplacements';

  /// Danh sách từ sửa lỗi, giữ thứ tự người dùng nhập. Bỏ qua phần tử hỏng
  /// (key rỗng, sai cấu trúc, file settings bị dính tay) thay vì crash.
  Future<List<WordFix>> getWordFixes() async {
    final raw = await getSetting(wordFixesKey);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final list = jsonDecode(raw) as List;
      return [for (final e in list) ?_parseWordFix(e)];
    } catch (_) {
      return const [];
    }
  }

  static WordFix? _parseWordFix(Object? e) {
    if (e is! List || e.length < 2 || e.length > 3) return null;
    if (e[0] is! String || e[1] is! String) return null;
    final from = e[0] as String;
    if (from.isEmpty) return null;
    if (e.length == 2) return WordFix(from, e[1] as String);
    // Phần tử thứ ba không phải chữ là dữ liệu hỏng — bỏ, không biến thành
    // mục chung kẻo áp nhầm cho mọi truyện.
    if (e[2] is! String) return null;
    if ((e[2] as String).isEmpty) return WordFix(from, e[1] as String);
    return WordFix(from, e[1] as String, storyUrl: e[2] as String);
  }

  Future<void> setWordFixes(List<WordFix> fixes) => setSetting(
    wordFixesKey,
    jsonEncode([
      for (final f in fixes)
        if (f.storyUrl == null) [f.from, f.to] else [f.from, f.to, f.storyUrl],
    ]),
  );

  /// Ký tự rác một số nguồn cài vào GIỮA các chữ để chống copy ("s.á.t" thay
  /// vì "sát"): dấu chấm và họ hàng của nó đứng kề sát chữ hai bên. Dấu chấm
  /// câu thật luôn có khoảng trắng hoặc hết câu sau nó nên không bị đụng tới;
  /// chấm lửng "tôi...anh" là RUN nhiều chấm — chỉ bỏ run ĐÚNG MỘT chấm để
  /// không xé vỡ dấu lười biếng.
  static final _dotJunk = RegExp(
    r'(?<=[\p{L}])[.·‧․∙•⋅](?=[\p{L}])',
    unicode: true,
  );

  /// Ký tự vô hình chen vào từ (zero-width space/ZWNJ/ZWJ, BOM, soft hyphen).
  static final _invisibleJunk = RegExp('[\u200B\u200C\u200D\uFEFF\u00AD]');

  static String _cleanJunk(String s) =>
      s.replaceAll(_invisibleJunk, '').replaceAll(_dotJunk, '');

  /// Áp danh sách sửa từ lên một chuỗi. Chuẩn hóa ký tự rác trước (người dùng
  /// nhập theo bản đã chuẩn hóa). Cùng cụm từ, bản của [storyUrl] thắng bản
  /// chung — không áp cả hai, kẻo thay hai lần. [storyUrl] null thì chỉ áp
  /// mục chung.
  static String applyWordFixes(
    String text,
    List<WordFix> fixes,
    String? storyUrl,
  ) {
    var s = _cleanJunk(text);
    final storyFroms = <String>{
      for (final f in fixes)
        if (f.storyUrl != null && f.sameScope(storyUrl)) f.from,
    };
    for (final f in fixes) {
      if (f.from.isEmpty) continue;
      final forThisStory = f.storyUrl != null && f.sameScope(storyUrl);
      if (f.storyUrl == null && storyFroms.contains(f.from)) continue;
      if (f.storyUrl != null && !forThisStory) continue;
      s = s.replaceAll(f.from, f.to);
    }
    return s;
  }

  /// Áp danh sách từ sửa lỗi vào tiêu đề + từng đoạn của nội dung chương.
  /// [storyUrl] là URL truyện màn đọc đang dùng — phải cùng giá trị lúc người
  /// dùng chọn "Chỉ truyện này", không đoán từ link chương. Khớp nguyên văn
  /// (phân biệt hoa thường), áp theo thứ tự trong danh sách. CHỈ gọi ở đường
  /// hiển thị/phát (màn đọc, nghe đọc) — không sửa trước khi ghi cache: cache
  /// giữ bản gốc thì xoá/sửa một cụm từ có tác dụng ngược ngay trên chương đã
  /// tải sẵn, không kẹt lỗi sai cũ.
  Future<ChapterContent> fixWords(ChapterContent c, {String? storyUrl}) async {
    final fixes = await getWordFixes();
    String fix(String s) => applyWordFixes(s, fixes, storyUrl);
    return ChapterContent(
      url: c.url,
      title: fix(c.title),
      paragraphs: [for (final pa in c.paragraphs) fix(pa)],
      nextUrl: c.nextUrl,
      prevUrl: c.prevUrl,
    );
  }
}
