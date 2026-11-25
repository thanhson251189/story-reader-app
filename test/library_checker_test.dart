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

class _ApiFetcher extends WebFetcher {
  NovelInfo? next;
  var apiCalls = 0;
  var webviewCalls = 0;

  @override
  Future<NovelInfo?> fetchStoryApiOnly(
    String url,
    SourceAdapter adapter,
  ) async {
    apiCalls++;
    return next;
  }

  @override
  Future<NovelInfo> fetchStory(String url, SourceAdapter adapter) async {
    webviewCalls++;
    throw Exception('không được rơi về WebView ở chế độ nền');
  }
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

  test('đang đọc dở không bị tính là có chương mới', () async {
    final db = AppDb(fileName: fileName);
    const story = 'https://x.test/truyen-do';
    await db.upsertLibrary(
      storyUrl: story,
      title: 'Truyện dở',
      lastChapterUrl: '$story/chuong-3',
    );
    await db.setLatestChapter(story, '$story/chuong-10', 'Chương 10');
    await db.saveToc(story, [
      for (var i = 1; i <= 10; i++)
        ChapterRef(title: 'Chương $i', url: '$story/chuong-$i'),
    ]);
    final repo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);
    final fetcher = _ScriptFetcher()
      ..next = NovelInfo(
        title: 'Truyện dở',
        chapters: [
          for (var i = 1; i <= 10; i++)
            ChapterRef(title: 'Chương $i', url: '$story/chuong-$i'),
        ],
      );

    final res = await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: Duration.zero,
      items: [
        {
          'story_url': story,
          'title': 'Truyện dở',
          'last_chapter_url': '$story/chuong-3',
          'latest_chapter_url': '$story/chuong-10',
        },
      ],
    );

    expect(res.fresh, 0);
  });

  test('chương cuối đổi so với lần kiểm tra trước thì tính là mới', () async {
    final db = AppDb(fileName: fileName);
    const story = 'https://x.test/truyen-moi-that';
    await db.upsertLibrary(
      storyUrl: story,
      title: 'Truyện mới',
      lastChapterUrl: '$story/chuong-10',
    );
    await db.setLatestChapter(story, '$story/chuong-10', 'Chương 10');
    final repo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);
    final fetcher = _ScriptFetcher()
      ..next = NovelInfo(
        title: 'Truyện mới',
        chapters: [
          for (var i = 1; i <= 11; i++)
            ChapterRef(title: 'Chương $i', url: '$story/chuong-$i'),
        ],
      );

    final res = await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: Duration.zero,
      items: [
        {
          'story_url': story,
          'title': 'Truyện mới',
          'last_chapter_url': '$story/chuong-10',
          'latest_chapter_url': '$story/chuong-10',
        },
      ],
    );

    expect(res.fresh, 1);
    final row = (await db.getLibrary())
        .where((r) => r['story_url'] == story)
        .single;
    expect(row['latest_chapter_url'], '$story/chuong-11');
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

  test('isDue: chưa từng kiểm tra thì đến hạn, trong 6 giờ thì chưa', () {
    final now = DateTime(2026, 11, 23, 12);
    expect(LibraryChecker.isDue(null, now), isTrue);
    expect(LibraryChecker.isDue(0, now), isTrue);
    final recent = now
        .subtract(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    expect(LibraryChecker.isDue(recent, now), isFalse);
    final old = now.subtract(const Duration(hours: 6)).millisecondsSinceEpoch;
    expect(LibraryChecker.isDue(old, now), isTrue);
  });

  test('hủy trong lúc nghỉ thì không kiểm tra truyện sau', () async {
    final db = AppDb(fileName: fileName);
    const a = 'https://x.test/truyen-huy-a';
    const b = 'https://x.test/truyen-huy-b';
    final repo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);
    final fetcher = _ScriptFetcher()
      ..next = NovelInfo(
        title: 'A',
        chapters: [ChapterRef(title: '1', url: '$a/1')],
      );
    final fut = LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: const Duration(seconds: 2),
      items: [
        {'story_url': a, 'title': 'A', 'last_chapter_url': null},
        {'story_url': b, 'title': 'B', 'last_chapter_url': null},
      ],
    );
    await Future<void>.delayed(const Duration(milliseconds: 200));
    LibraryChecker.cancel();
    final res = await fut.timeout(const Duration(seconds: 3));
    expect(res.cancelled, isTrue);
    expect(res.ran, isTrue);
    expect(LibraryChecker.running, isFalse);
  });

  test('chế độ nền chỉ gọi API JSON, bỏ nguồn không có API', () async {
    final db = AppDb(fileName: fileName);
    const apiStory = 'https://x.test/truyen-api';
    const plainStory = 'https://x.test/truyen-thuong';
    await db.upsertLibrary(
      storyUrl: apiStory,
      title: 'Truyện API',
      lastChapterUrl: '$apiStory/chuong-1',
    );
    await db.saveToc(apiStory, [
      ChapterRef(title: 'Chương 1', url: '$apiStory/chuong-1'),
    ]);
    await db.setLatestChapter(apiStory, '$apiStory/chuong-1', 'Chương 1');
    await db.upsertLibrary(
      storyUrl: plainStory,
      title: 'Truyện thường',
      lastChapterUrl: '$plainStory/chuong-1',
    );

    final repo = AdapterRepository([
      SourceAdapter.fromJson({
        'domain': 'x.test',
        'selectors': {},
        'api': {'storyUrl': 'https://api.x.test/{slug}'},
      }),
    ]);
    final fetcher = _ApiFetcher()
      ..next = NovelInfo(
        title: 'Truyện API',
        chapters: [
          ChapterRef(title: 'Chương 1', url: '$apiStory/chuong-1'),
          ChapterRef(title: 'Chương 2', url: '$apiStory/chuong-2'),
        ],
      );
    // Truyện thứ hai dùng cùng domain nhưng mục tiêu là kiểm tra nhánh bỏ
    // qua nguồn thiếu API: dùng repo riêng không có api.
    final plainRepo = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'x.test', 'selectors': {}}),
    ]);

    final res = await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: repo,
      gap: Duration.zero,
      apiOnly: true,
      items: [
        {
          'story_url': apiStory,
          'title': 'Truyện API',
          'latest_chapter_url': '$apiStory/chuong-1',
        },
      ],
    );
    expect(fetcher.webviewCalls, 0);
    expect(res.fresh, 1);
    expect(res.freshTitles, ['Truyện API']);

    final skipped = await LibraryChecker.check(
      db: db,
      fetcher: fetcher,
      repo: plainRepo,
      gap: Duration.zero,
      apiOnly: true,
      items: [
        {
          'story_url': plainStory,
          'title': 'Truyện thường',
          'latest_chapter_url': null,
        },
      ],
    );
    expect(skipped.fresh, 0);
    expect(skipped.warns, isEmpty);
    expect(fetcher.webviewCalls, 0);
  });
}
