import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/search/search_screen.dart';
import 'package:story_reader/sources/registry.dart';

void main() {
  test('SearchResult fromJson defaults', () {
    final r = SearchResult.fromJson({
      'title': 'Kiếm Đế',
      'url': 'https://truyendich.us/doc-truyen/kiem-de',
      'coverUrl': 'https://truyendich.us/anh-bia/kiem-de.webp',
    });
    expect(r.title, 'Kiếm Đế');
    expect(r.coverUrl, contains('kiem-de'));
    final empty = SearchResult.fromJson({});
    expect(empty.title, '');
    expect(empty.url, '');
    expect(empty.coverUrl, null);
  });

  test('SourceAdapter đọc searchUrl và withSearch giữ phần cũ', () {
    final a = SourceAdapter.fromJson({
      'domain': 'example.com',
      'selectors': {'content': '#c'},
    });
    expect(a.searchUrl, null);
    final b = a.withSearch('https://example.com/s?q={query}', {
      'searchList': 'a',
    });
    expect(b.searchUrl, 'https://example.com/s?q={query}');
    expect(b.selectors['content'], '#c');
    expect(b.selectors['searchList'], 'a');
    expect(
      a.selectors.containsKey('searchList'),
      false,
      reason: 'không mutate adapter gốc',
    );
  });

  test('withBuiltinSearch seed nguồn chính thức, remote thắng', () {
    final old = SourceAdapter.fromJson({
      'domain': 'truyendich.us',
      'selectors': {'content': '#c'},
    });
    final seeded = SourceRegistry.withBuiltinSearch(old);
    expect(seeded.searchUrl, contains('tim-kiem?q={query}'));
    expect(seeded.selectors['searchList'], "a[href^='/doc-truyen/']");

    final remote = SourceAdapter.fromJson({
      'domain': 'truyendich.us',
      'searchUrl': 'https://truyendich.us/tim?q={query}',
      'selectors': {'searchList': '.result'},
    });
    final kept = SourceRegistry.withBuiltinSearch(remote);
    expect(kept.searchUrl, 'https://truyendich.us/tim?q={query}');
    expect(kept.selectors['searchList'], '.result');

    final other = SourceAdapter.fromJson({'domain': 'khac.com'});
    expect(SourceRegistry.withBuiltinSearch(other).searchUrl, null);
  });

  test('searchUrlFor mã hoá từ khoá tiếng Việt', () {
    final a = SourceAdapter.fromJson({
      'domain': 'truyendich.us',
      'searchUrl': 'https://truyendich.us/tim-kiem?q={query}',
    });
    expect(
      WebFetcher.searchUrlFor(a, 'kiếm đế'),
      'https://truyendich.us/tim-kiem?q=ki%E1%BA%BFm%20%C4%91%E1%BA%BF',
    );
  });

  test('parseSearch bỏ kết quả thiếu title/url', () {
    final r = WebFetcher.parseSearch({
      'results': [
        {'title': 'Kiếm Đế', 'url': 'https://x.com/a'},
        {'title': '', 'url': 'https://x.com/b'},
        {'title': 'Thiếu url'},
      ],
    });
    expect(r.length, 1);
    expect(r.single.title, 'Kiếm Đế');
    expect(WebFetcher.parseSearch({}), isEmpty);
  });

  test('parseStory sort chương và giữ trang đơn không chương', () {
    final info = WebFetcher.parseStory({
      'title': 'Truyện',
      'chapters': [
        {'title': 'C2', 'url': 'https://x.com/chuong-2'},
        {'title': 'C1', 'url': 'https://x.com/chuong-1'},
      ],
    });
    expect(info.chapters.map((c) => c.url).toList(), [
      'https://x.com/chuong-1',
      'https://x.com/chuong-2',
    ]);
    final single = WebFetcher.parseStory({
      'title': 'Trang đơn',
      'hasContent': true,
      'chapters': [],
    });
    expect(single.chapters, isEmpty);
  });

  test('storyJs khai báo hasContent để phân biệt trang đơn với chặn bot', () {
    final a = SourceAdapter.fromJson({
      'domain': 'x.com',
      'selectors': {'content': '#c'},
    });
    expect(WebFetcher.storyJs(a), contains('hasContent'));
  });

  test('chapterJs tách đoạn theo dòng trong <p> (site dùng <br>)', () {
    final a = SourceAdapter.fromJson({
      'domain': 'x.com',
      'selectors': {'content': '.reading-content'},
    });
    final js = WebFetcher.chapterJs(a);
    expect(
      js,
      contains("flatMap(t => t.split(/\\n+/))"),
      reason: 'một số site nhét cả chương vào một <p> dài với <br>',
    );
  });

  test('toggleSource bỏ tích một nguồn khi đang chọn tất cả', () {
    final all = ['a.com', 'b.com', 'c.com'];
    final rest = SearchScreen.toggleSource(null, 'b.com', all);
    expect(rest, {'a.com', 'c.com'});
    expect(SearchScreen.toggleSource(rest, 'b.com', all), isNull);
  });

  test('toggleSource bỏ tích nguồn cuối thì không còn nguồn nào', () {
    final all = ['a.com', 'b.com'];
    final one = SearchScreen.toggleSource(null, 'a.com', all);
    expect(one, {'b.com'});
    expect(SearchScreen.toggleSource(one, 'b.com', all), isEmpty);
  });

  test('toggleSource từ trạng thái không chọn nguồn nào', () {
    final all = ['a.com', 'b.com'];
    expect(SearchScreen.toggleSource({}, 'a.com', all), {'a.com'});
  });

  test('summary tóm tắt lựa chọn nguồn', () {
    expect(SearchScreen.summary(null), 'Tất cả nguồn');
    expect(SearchScreen.summary({}), 'Chưa chọn nguồn');
    expect(SearchScreen.summary({'a.com'}), 'a.com');
    expect(SearchScreen.summary({'a.com', 'b.com'}), '2 nguồn đã chọn');
  });

  testWidgets('Bấm tiêu đề nguồn thu/mở kết quả của riêng nguồn đó', (
    tester,
  ) async {
    await _pumpSearch(tester);
    await _search(tester, 'kiem');

    expect(find.text('a.com'), findsOneWidget);
    expect(find.text('2 kết quả'), findsOneWidget);
    expect(find.text('Truyện a.com'), findsOneWidget);

    // Thu gọn: kết quả nguồn này biến mất, tiêu đề và số kết quả vẫn còn.
    await tester.tap(find.text('a.com'));
    await tester.pump();
    expect(find.text('Truyện a.com'), findsNothing);
    expect(find.text('Truyện a.com 2'), findsNothing);
    expect(find.text('a.com'), findsOneWidget);
    expect(find.text('2 kết quả'), findsOneWidget);
    // Nguồn khác không bị ảnh hưởng.
    expect(find.text('Truyện b.com'), findsOneWidget);

    // Mở lại được.
    await tester.tap(find.text('a.com'));
    await tester.pump();
    expect(find.text('Truyện a.com'), findsOneWidget);
  });

  testWidgets('Lần tìm mới mở lại nguồn đã thu gọn', (tester) async {
    await _pumpSearch(tester);
    await _search(tester, 'kiem');
    await tester.tap(find.text('a.com'));
    await tester.pump();
    expect(find.text('Truyện a.com'), findsNothing);

    await _search(tester, 'kiem moi');
    expect(find.text('Truyện a.com'), findsOneWidget);
    expect(find.text('Truyện b.com'), findsOneWidget);
  });
}

SourceAdapter _adapter(String domain) => SourceAdapter.fromJson({
  'domain': domain,
  'searchUrl': 'https://$domain/tim?q={query}',
  'selectors': {'searchList': 'a'},
});

class _FakeFetcher extends WebFetcher {
  @override
  Future<List<SearchResult>> searchStories(String query, SourceAdapter a) =>
      Future.value([
        // Số kết quả khác nhau theo nguồn để assert tiêu đề không lẫn nhau.
        for (var i = 1; i <= (a.domain == 'a.com' ? 2 : 3); i++)
          SearchResult(
            title: 'Truyện ${a.domain} ${i > 1 ? i : ''}'.trim(),
            url: 'https://${a.domain}/$i',
          ),
      ]);
}

class _FakeDb extends AppDb {
  @override
  Future<String?> getSetting(String key) async => null;

  @override
  Future<List<Map<String, dynamic>>> getLibrary() async => const [];
}

Future<void> _pumpSearch(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDbProvider.overrideWithValue(_FakeDb()),
        adapterRepoProvider.overrideWithValue(
          AdapterRepository([_adapter('a.com'), _adapter('b.com')]),
        ),
        webFetcherProvider.overrideWithValue(_FakeFetcher()),
      ],
      child: const MaterialApp(home: SearchScreen()),
    ),
  );
}

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField), query);
  await tester.tap(find.text('Tìm'));
  await tester.pump();
  await tester.pump();
}
