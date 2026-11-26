import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';

/// Test database thật (SQLite chạy trên máy phát triển qua FFI, không vào app
/// production). Xoá file db trước khi mở để mỗi lần chạy test là nền sạch.
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), 'story_reader.db');
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  test(
    'upsertLibrary giữ ô chương mới nhất + bìa khi ghi lại truyện đã có',
    () async {
      final db = AppDb();
      final storyUrl = 'https://x.test/truyen-a';
      await db.upsertLibrary(
        storyUrl: storyUrl,
        title: 'Truyện A',
        coverUrl: 'https://x.test/cover.png',
        lastChapterUrl: 'https://x.test/truyen-a/chuong-1',
      );
      await db.setLatestChapter(
        storyUrl,
        'https://x.test/truyen-a/chuong-99',
        'Chương 99',
      );

      // Mô phỏng "Làm mới mục lục": ghi lại truyện mà phần quét web không mang
      // theo bìa và chương mới nhất. REPLACE không được phép nuốt 2 ô đó.
      await db.saveStoryInfo(
        storyUrl,
        NovelInfo(
          title: 'Truyện A',
          coverUrl: null,
          chapters: [
            ChapterRef(
              title: 'Chương 1',
              url: 'https://x.test/truyen-a/chuong-1',
            ),
          ],
        ),
        lastChapterUrl: 'https://x.test/truyen-a/chuong-1',
      );

      final rows = await db.getLibrary();
      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row['latest_chapter_url'], 'https://x.test/truyen-a/chuong-99');
      expect(row['latest_chapter_title'], 'Chương 99');
      expect(row['cover_url'], 'https://x.test/cover.png');
      expect(row['last_chapter_url'], 'https://x.test/truyen-a/chuong-1');
      await (await db.database).close();
    },
  );

  test('saveStoryInfo lưu mục lục và library đúng cặp story', () async {
    final db = AppDb();
    final storyUrl = 'https://x.test/truyen-b';
    await db.saveStoryInfo(
      storyUrl,
      NovelInfo(
        title: 'Truyện B',
        coverUrl: 'https://x.test/b.png',
        chapters: [
          ChapterRef(title: 'Mở đầu', url: 'https://x.test/truyen-b/mo-dau'),
          ChapterRef(
            title: 'Chương 1',
            url: 'https://x.test/truyen-b/chuong-1',
          ),
        ],
      ),
      lastChapterUrl: 'https://x.test/truyen-b/mo-dau',
    );
    final toc = await db.getToc(storyUrl);
    expect(toc.map((c) => c.title), ['Mở đầu', 'Chương 1']);
    final rows = await db.getLibrary();
    final row = rows.firstWhere((r) => r['story_url'] == storyUrl);
    expect(row['title'], 'Truyện B');
    expect(row['last_chapter_url'], 'https://x.test/truyen-b/mo-dau');
    await (await db.database).close();
  });

  test('chapterNeighbors suy chương trước/sau từ mục lục đã lưu', () async {
    final db = AppDb();
    const storyUrl = 'https://dammyy.cc/truyen-c.html';
    await db.saveStoryInfo(
      storyUrl,
      NovelInfo(
        title: 'Truyện C',
        chapters: [
          ChapterRef(
            title: 'C1',
            url: 'https://dammyy.cc/truyen-c/chuong-1.html',
          ),
          ChapterRef(
            title: 'C2',
            url: 'https://dammyy.cc/truyen-c/chuong-2.html',
          ),
          ChapterRef(
            title: 'C3',
            url: 'https://dammyy.cc/truyen-c/chuong-3.html',
          ),
        ],
      ),
    );
    expect(
      await db.chapterNeighbors('https://dammyy.cc/truyen-c/chuong-1.html'),
      (null, 'https://dammyy.cc/truyen-c/chuong-2.html'),
    );
    expect(
      await db.chapterNeighbors('https://dammyy.cc/truyen-c/chuong-2.html'),
      (
        'https://dammyy.cc/truyen-c/chuong-1.html',
        'https://dammyy.cc/truyen-c/chuong-3.html',
      ),
    );
    expect(
      await db.chapterNeighbors('https://dammyy.cc/truyen-c/chuong-3.html'),
      ('https://dammyy.cc/truyen-c/chuong-2.html', null),
    );
    // Chương không có trong mục lục nào: không suy được.
    expect(await db.chapterNeighbors('https://dammyy.cc/khac/chuong-9.html'), (
      null,
      null,
    ));
    await (await db.database).close();
  });

  test('chapterNeighbors khớp URL chuẩn hóa, fillNav bù chương kế', () async {
    final db = AppDb();
    await db.saveToc('https://s.com/truyen', [
      ChapterRef(title: 'Chương 1', url: 'https://s.com/truyen/c-1'),
      // Mục lục lưu URL có slash cuối — lệch với form màn đọc nhận được.
      ChapterRef(title: 'Chương 2', url: 'https://s.com/truyen/c-2/'),
      ChapterRef(title: 'Chương 3', url: 'https://s.com/truyen/c-3'),
    ]);

    // Màn đọc nhận URL KHÔNG slash cuối: vẫn phải tìm thấy nhờ chuẩn hóa.
    final (prev, next) = await db.chapterNeighbors('https://s.com/truyen/c-2');
    expect(prev, 'https://s.com/truyen/c-1');
    expect(next, 'https://s.com/truyen/c-3');

    // Chương tải về thiếu prev/next (nguồn không có nút chuyển chương):
    // fillNav bù từ mục lục, giữ nguyên các trường khác.
    final filled = await db.fillNav(
      ChapterContent(
        url: 'https://s.com/truyen/c-2/',
        title: 'Chương 2',
        paragraphs: ['Nội dung'],
      ),
    );
    expect(filled.prevUrl, 'https://s.com/truyen/c-1');
    expect(filled.nextUrl, 'https://s.com/truyen/c-3');
    expect(filled.title, 'Chương 2');
    expect(filled.paragraphs, ['Nội dung']);

    // Chương đã có link trên trang: link trên trang thắng, chỉ bù phần thiếu.
    final intact = await db.fillNav(
      ChapterContent(
        url: 'https://s.com/truyen/c-2',
        title: 'Chương 2',
        paragraphs: ['Nội dung'],
        nextUrl: 'https://s.com/truyen/c-9',
      ),
    );
    expect(intact.nextUrl, 'https://s.com/truyen/c-9');
    expect(intact.prevUrl, 'https://s.com/truyen/c-1');
    await (await db.database).close();
  });

  test(
    'cacheChapters giữ ghim khi ghi đè và không ghim nhầm chương mới',
    () async {
      final db = AppDb(fileName: 'db_pin_batch_test.db');
      final u1 = 'https://p.test/chuong-1';
      final u2 = 'https://p.test/chuong-2';
      await db.cacheChapter(
        ChapterContent(url: u1, title: 'C1', paragraphs: ['a']),
      );
      await db.pinChapter(u1);
      // Ghi đè chương đã ghim cùng lúc với chương mới chưa từng có (như nạp
      // lại 1 chương + tải trước chèn vào): ghim cũ phải giữ, mới phải 0.
      await db.cacheChapters([
        ChapterContent(url: u1, title: 'C1 mới', paragraphs: ['a2']),
        ChapterContent(url: u2, title: 'C2', paragraphs: ['b']),
      ]);
      expect((await db.getCachedChapter(u1))!.title, 'C1 mới');
      expect(await db.pinnedWebCount(), 1);
      // Xoá dữ liệu tải sẵn: chương ghim còn, chương thường mất.
      await db.clearWebCache();
      expect(await db.getCachedChapter(u1), isNotNull);
      expect(await db.getCachedChapter(u2), isNull);
      await (await db.database).close();
    },
  );

  test(
    'cacheChapters trên đợt >500 chương vẫn giữ ghim đúng (chia lô IN)',
    () async {
      final db = AppDb(fileName: 'db_pin_batch_big_test.db');
      String url(int i) => 'https://big.test/c-$i';
      // Ghim 3 chương rải rác rồi ghi đè cả 1200 chương trong một lượt.
      final pinned = <int>{0, 501, 1199};
      for (final i in pinned) {
        await db.cacheChapter(
          ChapterContent(url: url(i), title: 'C$i', paragraphs: ['x']),
        );
        await db.pinChapter(url(i));
      }
      await db.cacheChapters([
        for (var i = 0; i < 1200; i++)
          ChapterContent(url: url(i), title: 'C$i mới', paragraphs: ['y']),
      ]);
      final rows = await (await db.database).query(
        'chapter_cache',
        columns: ['url'],
        where: 'pinned = 1',
      );
      expect(
        rows.map((r) => r['url']).toSet(),
        pinned.map((i) => url(i)).toSet(),
      );
      await (await db.database).close();
    },
  );

  test('bookmark: toggle thêm rồi xoá, list mới nhất lên đầu', () async {
    final db = AppDb();
    final added1 = await db.toggleBookmark(
      storyUrl: 's',
      chapterUrl: 'c1',
      chapterTitle: 'Chương 1',
      paraIndex: 3,
      snippet: 'đoạn A',
    );
    final added2 = await db.toggleBookmark(
      storyUrl: 's',
      chapterUrl: 'c2',
      chapterTitle: 'Chương 2',
      paraIndex: 1,
      snippet: 'đoạn B',
    );
    expect(added1, isTrue);
    expect(added2, isTrue);
    final list = await db.getBookmarks('s');
    expect(list.length, 2);
    expect(list.first['chapter_url'], 'c2');

    // Toggle lần nữa trên c1: xoá đánh dấu đó.
    final added3 = await db.toggleBookmark(
      storyUrl: 's',
      chapterUrl: 'c1',
      chapterTitle: 'Chương 1',
      paraIndex: 3,
      snippet: 'đoạn A',
    );
    expect(added3, isFalse);
    final after = await db.getBookmarks('s');
    expect(after.length, 1);
    expect(after.single['chapter_url'], 'c2');
    // Truyện khác không thấy đánh dấu của truyện 's'.
    expect(await db.getBookmarks('other'), isEmpty);
    await db.removeBookmark(after.single['id'] as int);
    expect(await db.getBookmarks('s'), isEmpty);
  });

  test('bookmark: dedupe theo (story, chapter, para)', () async {
    final db = AppDb();
    await db.toggleBookmark(
      storyUrl: 'sdup',
      chapterUrl: 'cdup',
      chapterTitle: 'C',
      paraIndex: 2,
      snippet: 'a',
    );
    await db.toggleBookmark(
      storyUrl: 'sdup',
      chapterUrl: 'cdup',
      chapterTitle: 'C',
      paraIndex: 2,
      snippet: 'b',
    );
    expect(await db.getBookmarks('sdup'), isEmpty);
    await db.toggleBookmark(
      storyUrl: 'sdup',
      chapterUrl: 'cdup',
      chapterTitle: 'C',
      paraIndex: 2,
      snippet: 'b',
    );
    final list = await db.getBookmarks('sdup');
    expect(list.single['snippet'], 'b');
    await db.removeFromLibrary('sdup');
    expect(await db.getBookmarks('sdup'), isEmpty);
  });

  test(
    'cache, vị trí đọc và ghim khớp khi link lệch slash hoặc http',
    () async {
      const name = 'url_norm_lookup.db';
      final path = p.join(await getDatabasesPath(), name);
      if (await databaseFactory.databaseExists(path)) {
        await databaseFactory.deleteDatabase(path);
      }
      final db = AppDb(fileName: name);
      const stored = 'https://x.test/truyen/chuong-1/';
      const opened = 'https://x.test/truyen/chuong-1';
      await db.cacheChapter(
        ChapterContent(
          url: stored,
          title: 'C1',
          paragraphs: const ['nội dung đầy đủ'],
        ),
      );
      await db.savePosition(stored, 120);

      final hit = await db.getCachedChapter(opened);
      expect(hit, isNotNull);
      expect(hit!.paragraphs, ['nội dung đầy đủ']);
      expect(
        await db.getCachedChapter('http://x.test/truyen/chuong-1'),
        isNotNull,
      );
      expect(await db.getPosition(opened), 120);
      expect(await db.chapterFetchedAt(opened), isNotNull);

      await db.pinChapter(opened);
      expect(await db.pinnedWebCount(), 1);
      await db.pruneChapterCache(keep: 0);
      expect(await db.getCachedChapter(opened), isNotNull);

      await db.cacheChapter(
        ChapterContent(url: 'book:abc:0', title: 'B', paragraphs: const ['x']),
      );
      expect(await db.getCachedChapter('book:abc:1'), isNull);
      await (await db.database).close();
    },
  );

  test('mở lại chương không làm mới ngày tải từ web', () async {
    const name = 'db_stamp_test.db';
    final path = p.join(await getDatabasesPath(), name);
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
    final db = AppDb(fileName: name);
    const url = 'https://stamp.test/chuong-1';
    await db.cacheChapter(
      ChapterContent(url: url, title: 'C', paragraphs: const ['a']),
    );
    final at = await db.chapterFetchedAt(url);
    await db.cacheChapter(
      ChapterContent(url: url, title: 'C', paragraphs: const ['a']),
      touchFetchedAt: false,
    );
    expect(await db.chapterFetchedAt(url), at);
    await (await db.database).close();
  });

  test('nâng cấp v8 → v9: backfill norm và tra cứu lệch URL vẫn khớp', () async {
    const name = 'db_migrate_v9_test.db';
    final path = p.join(await getDatabasesPath(), name);
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
    // Dựng DB phiên bản 8 y như bản cũ: chưa có cột norm_*.
    final old = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
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
          await db.execute(
            'CREATE TABLE bookmarks(id INTEGER PRIMARY KEY AUTOINCREMENT, story_url TEXT NOT NULL, chapter_url TEXT NOT NULL, chapter_title TEXT NOT NULL, para_index INTEGER NOT NULL, snippet TEXT NOT NULL, created_at INTEGER NOT NULL, UNIQUE(story_url, chapter_url, para_index))',
          );
        },
      ),
    );
    const story = 'https://x.test/truyen/';
    await old.insert('library', {
      'story_url': story,
      'title': 'Truyện',
      'last_chapter_url': '${story}chuong-2',
      'updated_at': 1,
    });
    await old.insert('toc', {
      'story_url': story,
      'chapter_url': '${story}chuong-1',
      'title': 'C1',
      'idx': 0,
    });
    await old.insert('toc', {
      'story_url': story,
      'chapter_url': '${story}chuong-2',
      'title': 'C2',
      'idx': 1,
    });
    await old.insert('positions', {
      'url': '${story}chuong-2/',
      'offset': 40.0,
      'updated_at': 5,
    });
    await old.insert('chapter_cache', {
      'url': '${story}chuong-2/',
      'title': 'C2',
      'content': '["a"]',
      'fetched_at': 5,
    });
    await old.insert('bookmarks', {
      'story_url': story,
      'chapter_url': '${story}chuong-2',
      'chapter_title': 'C2',
      'para_index': 1,
      'snippet': 'x',
      'created_at': 1,
    });
    await old.close();

    // Lần mở này nâng cấp lên v9 và backfill norm.
    final db = AppDb(fileName: name);
    expect(await db.getPosition('https://x.test/truyen/chuong-2'), 40);
    expect(
      await db.getCachedChapter('https://x.test/truyen/chuong-2'),
      isNotNull,
    );
    expect(await db.getToc('https://x.test/truyen'), hasLength(2));
    expect(await db.isInLibrary('https://x.test/truyen'), isTrue);
    expect(await db.getBookmarks('https://x.test/truyen'), hasLength(1));
    expect((await db.tocCountByStory())['x.test/truyen'], 2);
    expect(
      await db.chapterNeighbors('http://x.test/truyen/chuong-2'),
      ('https://x.test/truyen/chuong-1', null),
    );
    await (await db.database).close();
  });

  test(
    'link truyện lệch slash vẫn cập nhật đang đọc và lấy được mục lục',
    () async {
      const name = 'db_story_key_test.db';
      final path = p.join(await getDatabasesPath(), name);
      if (await databaseFactory.databaseExists(path)) {
        await databaseFactory.deleteDatabase(path);
      }
      final db = AppDb(fileName: name);
      const stored = 'https://x.test/truyen/';
      const opened = 'https://x.test/truyen';
      await db.upsertLibrary(
        storyUrl: stored,
        title: 'Truyện',
        lastChapterUrl: '$stored/chuong-1',
      );
      await db.saveToc(stored, [
        ChapterRef(title: 'C1', url: 'https://x.test/truyen/chuong-1'),
        ChapterRef(title: 'C2', url: 'https://x.test/truyen/chuong-2'),
      ]);

      await db.touchLibrary(opened, 'https://x.test/truyen/chuong-2');
      final row = (await db.getLibrary()).single;
      expect(row['story_url'], stored);
      expect(row['last_chapter_url'], 'https://x.test/truyen/chuong-2');
      expect(await db.getToc(opened), hasLength(2));

      await db.savePosition('https://x.test/truyen/chuong-2', 40);
      await db.removeFromLibrary(opened);
      expect(await db.getLibrary(), isEmpty);
      expect(await db.getToc(stored), isEmpty);
      expect(await db.getPosition('https://x.test/truyen/chuong-2'), isNull);
      await (await db.database).close();
    },
  );
}
