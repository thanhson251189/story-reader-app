import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/chapter_prefetcher.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';

class _FakeDb extends AppDb {
  final Map<String, ChapterContent> cache = {};
  final Map<String, String> settings = {};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<ChapterContent?> getCachedChapter(String url) async => cache[url];

  @override
  Future<void> cacheChapter(ChapterContent c) async {
    cache[c.url] = c;
  }
}

class _FakeFetcher extends WebFetcher {
  final Map<String, ChapterContent> pages;
  final Set<String> errorOn;
  final List<String> fetched = [];

  _FakeFetcher(this.pages, {this.errorOn = const {}});

  @override
  Future<ChapterContent> fetchChapter(String url, SourceAdapter adapter) async {
    fetched.add(url);
    if (errorOn.contains(url)) throw Exception('Lỗi mạng giả lập: $url');
    final c = pages[url];
    if (c == null) throw Exception('Không có chương: $url');
    return c;
  }
}

void main() {
  const domain = 'https://example.com';
  String url(int i) => '$domain/$i';

  Map<String, ChapterContent> chain(int n) => {
    for (var i = 1; i <= n; i++)
      url(i): ChapterContent(
        url: url(i),
        title: 'Chương $i',
        paragraphs: ['Nội dung $i'],
        nextUrl: i < n ? url(i + 1) : null,
        prevUrl: i > 1 ? url(i - 1) : null,
      ),
  };

  AdapterRepository repo() => AdapterRepository([
    SourceAdapter.fromJson({
      'id': 'test',
      'domain': 'example.com',
      'version': 1,
      'selectors': {'content': '#content'},
    }),
  ]);

  ChapterPrefetcher make(
    _FakeDb db,
    _FakeFetcher fetcher, {
    Duration gap = Duration.zero,
  }) => ChapterPrefetcher(db: db, fetcher: fetcher, adapters: repo(), gap: gap);

  test('mặc định tải 3 chương kế rồi dừng, ghi vào cache', () async {
    final db = _FakeDb();
    final fetcher = _FakeFetcher(chain(6));
    await make(db, fetcher).prefetch(url(2));
    expect(fetcher.fetched, [url(2), url(3), url(4)]);
    expect(db.cache.containsKey(url(4)), true);
  });

  test('bỏ qua chương đã cache, không tải lại', () async {
    final db = _FakeDb();
    final pages = chain(6);
    db.cache[url(2)] = pages[url(2)]!;
    final fetcher = _FakeFetcher(pages);
    await make(db, fetcher).prefetch(url(2));
    expect(fetcher.fetched, [
      url(3),
      url(4),
    ], reason: 'hết 3 chương tính cả chương đã cache');
  });

  test('dừng khi lỗi mạng, không ném lỗi ra ngoài', () async {
    final db = _FakeDb();
    final fetcher = _FakeFetcher(chain(6), errorOn: {url(3)});
    await make(db, fetcher).prefetch(url(2));
    expect(fetcher.fetched, [url(2), url(3)]);
  });

  test('lệnh prefetch mới huỷ chuỗi cũ đang nghỉ', () async {
    final db = _FakeDb();
    final fetcher = _FakeFetcher(chain(6));
    final p = make(db, fetcher, gap: const Duration(milliseconds: 100));
    final f1 = p.prefetch(url(2));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fetcher.fetched, [url(2)]);
    final f2 = p.prefetch(url(4));
    await Future.wait([f1, f2]);
    expect(fetcher.fetched, [
      url(2),
      url(4),
      url(5),
      url(6),
    ], reason: 'chuỗi cũ không được tải chương 3 nữa');
  });

  test('số chương theo setting, kẹp trong khoảng 1-5', () async {
    final db1 = _FakeDb();
    db1.settings['prefetchCount'] = '1';
    final f1 = _FakeFetcher(chain(8));
    await make(db1, f1).prefetch(url(2));
    expect(f1.fetched, [url(2)]);

    final db2 = _FakeDb();
    db2.settings['prefetchCount'] = '9';
    final f2 = _FakeFetcher(chain(8));
    await make(db2, f2).prefetch(url(2));
    expect(f2.fetched, [url(2), url(3), url(4), url(5), url(6)]);

    final db3 = _FakeDb();
    db3.settings['prefetchCount'] = 'abc';
    final f3 = _FakeFetcher(chain(8));
    await make(db3, f3).prefetch(url(2));
    expect(f3.fetched, [
      url(2),
      url(3),
      url(4),
    ], reason: 'setting hỏng về mặc định 3');
  });

  test('không tải sách cục bộ và dừng khi hết chương', () async {
    final db = _FakeDb();
    final fetcher = _FakeFetcher(chain(2));
    final p = make(db, fetcher);
    await p.prefetch('book:abc:2');
    expect(fetcher.fetched, isEmpty);
    await p.prefetch(url(2));
    expect(fetcher.fetched, [url(2)], reason: 'chương cuối không có nextUrl');
  });

  test('mặc định nghỉ 5s giữa các lần tải', () async {
    final db = _FakeDb();
    final fetcher = _FakeFetcher(chain(6));
    final p = ChapterPrefetcher(db: db, fetcher: fetcher, adapters: repo());
    final f1 = p.prefetch(url(2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(fetcher.fetched, [url(2)], reason: 'chưa hết 5s chưa tải chương kế');
    final f2 = p.prefetch(null);
    await Future.wait([f1, f2]);
    expect(fetcher.fetched, [url(2)]);
  });
}
