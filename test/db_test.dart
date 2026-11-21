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

  test('upsertLibrary giữ ô chương mới nhất + bìa khi ghi lại truyện đã có', () async {
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
      NovelInfo(title: 'Truyện A', coverUrl: null, chapters: [
        ChapterRef(title: 'Chương 1', url: 'https://x.test/truyen-a/chuong-1'),
      ]),
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
  });

  test('saveStoryInfo lưu mục lục và library đúng cặp story', () async {
    final db = AppDb();
    final storyUrl = 'https://x.test/truyen-b';
    await db.saveStoryInfo(
      storyUrl,
      NovelInfo(title: 'Truyện B', coverUrl: 'https://x.test/b.png', chapters: [
        ChapterRef(title: 'Mở đầu', url: 'https://x.test/truyen-b/mo-dau'),
        ChapterRef(title: 'Chương 1', url: 'https://x.test/truyen-b/chuong-1'),
      ]),
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
}
