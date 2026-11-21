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

  test('chapterNeighbors suy chương trước/sau từ mục lục đã lưu', () async {
    final db = AppDb();
    const storyUrl = 'https://dammyy.cc/truyen-c.html';
    await db.saveStoryInfo(
      storyUrl,
      NovelInfo(title: 'Truyện C', chapters: [
        ChapterRef(title: 'C1', url: 'https://dammyy.cc/truyen-c/chuong-1.html'),
        ChapterRef(title: 'C2', url: 'https://dammyy.cc/truyen-c/chuong-2.html'),
        ChapterRef(title: 'C3', url: 'https://dammyy.cc/truyen-c/chuong-3.html'),
      ]),
    );
    expect(
      await db.chapterNeighbors('https://dammyy.cc/truyen-c/chuong-1.html'),
      (null, 'https://dammyy.cc/truyen-c/chuong-2.html'),
    );
    expect(
      await db.chapterNeighbors('https://dammyy.cc/truyen-c/chuong-2.html'),
      (
        'https://dammyy.cc/truyen-c/chuong-1.html',
        'https://dammyy.cc/truyen-c/chuong-3.html'
      ),
    );
    expect(
      await db.chapterNeighbors('https://dammyy.cc/truyen-c/chuong-3.html'),
      ('https://dammyy.cc/truyen-c/chuong-2.html', null),
    );
    // Chương không có trong mục lục nào: không suy được.
    expect(await db.chapterNeighbors('https://dammyy.cc/khac/chuong-9.html'),
        (null, null));
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
}
