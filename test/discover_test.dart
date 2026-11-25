import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/discover/discover_opener.dart';
import 'package:story_reader/discover/discover_screen.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';

SourceAdapter adapter() => SourceAdapter(
  domain: 'x.test',
  version: 1,
  selectors: const {},
  removeSelectors: const [],
  textCleanup: const [],
);

class FakeFetcher extends WebFetcher {
  final ChapterContent? chapter;
  final NovelInfo? story;
  int storyCalls = 0;

  FakeFetcher({this.chapter, this.story});

  @override
  Future<ChapterContent> fetchChapter(String url, SourceAdapter a) async =>
      chapter ??
      ChapterContent(url: url, title: '', paragraphs: const []);

  @override
  Future<NovelInfo> fetchStory(String url, SourceAdapter a) async {
    storyCalls++;
    return story ?? NovelInfo(title: '', chapters: const []);
  }
}

class FakeAppDb extends AppDb {
  @override
  Future<String?> getSetting(String key) async => null;

  @override
  Future<void> setSetting(String key, String value) async {}

  @override
  Future<List<Map<String, dynamic>>> getLibrary() async => const [];
}

void main() {
  test('opener: trang chương có nội dung thì nhận là chương, không tải mục lục',
      () async {
    final fetcher = FakeFetcher(
      chapter: ChapterContent(
        url: 'https://x.test/truyen/chuong-2/',
        title: 'Chương 2',
        paragraphs: const ['Nội dung chương.'],
      ),
    );
    final page = await DiscoverOpener(
      fetcher: fetcher,
      repo: AdapterRepository([adapter()]),
    ).open('https://x.test/truyen/chuong-2/');
    expect(page.chapter?.title, 'Chương 2');
    expect(page.story, isNull);
    expect(fetcher.storyCalls, 0, reason: 'khỏi tải mục lục khi đã ra chương');
  });

  test('opener: trang truyện không có nội dung chương thì đọc mục lục', () async {
    final fetcher = FakeFetcher(
      story: NovelInfo(
        title: 'Kiếm Đạo',
        chapters: [
          ChapterRef(title: 'Chương 1', url: 'https://x.test/t/chuong-1'),
        ],
      ),
    );
    final page = await DiscoverOpener(
      fetcher: fetcher,
      repo: AdapterRepository([adapter()]),
    ).open('https://x.test/t');
    expect(page.story?.title, 'Kiếm Đạo');
    expect(page.chapter, isNull);
    expect(fetcher.storyCalls, 1);
  });

  test('opener: trang lạ thì báo không nhận ra', () async {
    final page = await DiscoverOpener(
      fetcher: FakeFetcher(),
      repo: AdapterRepository([adapter()]),
    ).open('https://x.test/trang-chu');
    expect(page.story, isNull);
    expect(page.chapter, isNull);
    expect(page.error, contains('Không nhận ra'));
  });

  test('opener: nguồn chưa cài thì báo rõ', () async {
    final page = await DiscoverOpener(
      fetcher: FakeFetcher(),
      repo: AdapterRepository([]),
    ).open('https://x.test/t');
    expect(page.error, contains('chưa cài'));
  });

  test('homeUrl lấy trang chủ theo domain nguồn', () {
    expect(
      DiscoverScreen.homeUrl(adapterWithDomain('truyendich.vn')),
      'https://truyendich.vn/',
    );
  });

  testWidgets('Khám phá: chưa cài nguồn thì hướng dẫn mở Nguồn truyện', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(FakeAppDb()),
          adapterRepoProvider.overrideWithValue(AdapterRepository([])),
        ],
        child: const MaterialApp(home: DiscoverScreen(active: true)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chưa cài nguồn truyện'), findsOneWidget);
    expect(find.text('Mở Nguồn truyện'), findsOneWidget);
  });
}

SourceAdapter adapterWithDomain(String domain) => SourceAdapter(
  domain: domain,
  version: 1,
  selectors: const {},
  removeSelectors: const [],
  textCleanup: const [],
);
