import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/library/library_checker.dart';

/// Mục lục giả: trả đúng bản được giao, không đụng mạng.
class _ScriptFetcher extends WebFetcher {
  NovelInfo? next;
  @override
  Future<NovelInfo> fetchStory(String url, SourceAdapter adapter) async =>
      next!;
}

void main() {
  const fileName = 'test_library_checker.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), fileName);
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  test('kiểm tra ngầm không ghi đè mục lục đủ bằng danh sách thiếu', () async {
    final db = AppDb(fileName: fileName);
    const story = 'https://x.test/truyen-a';
    await db.upsertLibrary(
      storyUrl: story,
      title: 'Truyện A',
      lastChapterUrl: '$story/chuong-3',
    );
    await db.saveToc(story, [
      for (var i = 1; i <= 3; i++)
        ChapterRef(title: 'Chương $i', url: '$story/chuong-$i'),
    ]);
    final repo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);
    final fetcher = _ScriptFetcher()
      ..next = NovelInfo(
        title: 'Truyện A',
        chapters: [ChapterRef(title: 'Chương 1', url: '$story/chuong-1')],
        tocComplete: false,
      );

    final res = await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: Duration.zero,
      items: [
        {
          'story_url': story,
          'title': 'Truyện A',
          'last_chapter_url': '$story/chuong-3',
        },
      ],
    );

    expect((await db.getToc(story)).length, 3);
    expect(res.fresh, 0);
    expect(res.warns.single, contains('giữ danh sách chương cũ'));
    final row = (await db.getLibrary())
        .where((r) => r['story_url'] == story)
        .single;
    expect(row['latest_chapter_url'], isNull);
    expect(row['last_chapter_url'], '$story/chuong-3');
  });

  test('danh sách ngắn hơn dù đánh dấu đủ cũng không đè mục lục cũ', () async {
    final db = AppDb(fileName: fileName);
    const story = 'https://x.test/truyen-b';
    await db.upsertLibrary(
      storyUrl: story,
      title: 'Truyện B',
      lastChapterUrl: '$story/chuong-2',
    );
    await db.saveToc(story, [
      ChapterRef(title: '1', url: '$story/chuong-1'),
      ChapterRef(title: '2', url: '$story/chuong-2'),
    ]);
    final repo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);
    final fetcher = _ScriptFetcher()
      ..next = NovelInfo(
        title: 'Truyện B',
        chapters: [ChapterRef(title: '1', url: '$story/chuong-1')],
      );

    await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: Duration.zero,
      items: [
        {
          'story_url': story,
          'title': 'Truyện B',
          'last_chapter_url': '$story/chuong-2',
        },
      ],
    );

    expect((await db.getToc(story)).length, 2);
  });

  test('link lệch slash cuối không bị tính là chương mới', () async {
    final db = AppDb(fileName: fileName);
    const story = 'https://x.test/truyen-c';
    await db.upsertLibrary(
      storyUrl: story,
      title: 'Truyện C',
      lastChapterUrl: '$story/chuong-4',
    );
    await db.saveToc(story, [ChapterRef(title: '4', url: '$story/chuong-4')]);
    final repo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);
    final fetcher = _ScriptFetcher()
      ..next = NovelInfo(
        title: 'Truyện C',
        chapters: [ChapterRef(title: '4', url: '$story/chuong-4/')],
      );

    final res = await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: Duration.zero,
      items: [
        {
          'story_url': story,
          'title': 'Truyện C',
          'last_chapter_url': '$story/chuong-4',
        },
      ],
    );

    expect(res.fresh, 0);
    expect(res.warns, isEmpty);
  });

  test('saveTocUnlessShorter không thêm truyện vào thư viện', () async {
    final db = AppDb(fileName: fileName);
    const story = 'https://x.test/truyen-tim';
    final saved = await db.saveTocUnlessShorter(
      story,
      NovelInfo(
        title: 'Từ tìm kiếm',
        chapters: [ChapterRef(title: '1', url: '$story/1')],
      ),
    );
    expect(saved, isTrue);
    expect(await db.getToc(story), hasLength(1));
    expect(
      (await db.getLibrary()).where((r) => r['story_url'] == story),
      isEmpty,
    );

    final kept = await db.saveTocUnlessShorter(
      story,
      NovelInfo(
        title: 'Thiếu',
        chapters: [ChapterRef(title: '1', url: '$story/1')],
        tocComplete: false,
      ),
    );
    expect(kept, isFalse);
    expect(await db.getToc(story), hasLength(1));
  });
}
