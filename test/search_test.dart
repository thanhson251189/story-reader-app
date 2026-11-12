import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/search/search_screen.dart';
import 'package:story_reader/sources/registry.dart';

void main() {
  test('SearchResult fromJson defaults', () {
    final r = SearchResult.fromJson({
      'title': 'Kiếm Đế',
      'url': 'https://truyendich.space/doc-truyen/kiem-de',
      'coverUrl': 'https://truyendich.space/anh-bia/kiem-de.webp',
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
      'domain': 'truyendich.space',
      'selectors': {'content': '#c'},
    });
    final seeded = SourceRegistry.withBuiltinSearch(old);
    expect(seeded.searchUrl, contains('tim-kiem?q={query}'));
    expect(seeded.selectors['searchList'], "a[href^='/doc-truyen/']");

    final remote = SourceAdapter.fromJson({
      'domain': 'truyendich.space',
      'searchUrl': 'https://truyendich.space/tim?q={query}',
      'selectors': {'searchList': '.result'},
    });
    final kept = SourceRegistry.withBuiltinSearch(remote);
    expect(kept.searchUrl, 'https://truyendich.space/tim?q={query}');
    expect(kept.selectors['searchList'], '.result');

    final other = SourceAdapter.fromJson({'domain': 'khac.com'});
    expect(SourceRegistry.withBuiltinSearch(other).searchUrl, null);
  });

  test('searchUrlFor mã hoá từ khoá tiếng Việt', () {
    final a = SourceAdapter.fromJson({
      'domain': 'truyendich.space',
      'searchUrl': 'https://truyendich.space/tim-kiem?q={query}',
    });
    expect(
      WebFetcher.searchUrlFor(a, 'kiếm đế'),
      'https://truyendich.space/tim-kiem?q=ki%E1%BA%BFm%20%C4%91%E1%BA%BF',
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

  test('toggleSource bỏ tích một nguồn khi đang chọn tất cả', () {
    final all = ['a.com', 'b.com', 'c.com'];
    final rest = SearchScreen.toggleSource({}, 'b.com', all);
    expect(rest, {'a.com', 'c.com'});
    expect(SearchScreen.toggleSource(rest, 'b.com', all), isEmpty);
  });

  test('toggleSource bỏ tích nguồn cuối thì quay về tất cả', () {
    final all = ['a.com', 'b.com'];
    final one = SearchScreen.toggleSource({}, 'a.com', all);
    expect(one, {'b.com'});
    expect(SearchScreen.toggleSource(one, 'b.com', all), isEmpty);
  });

  test('summary tóm tắt lựa chọn nguồn', () {
    expect(SearchScreen.summary({}), 'Tất cả nguồn');
    expect(SearchScreen.summary({'a.com'}), 'a.com');
    expect(SearchScreen.summary({'a.com', 'b.com'}), '2 nguồn đã chọn');
  });
}
