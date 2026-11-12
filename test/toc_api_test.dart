import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';

void main() {
  test('SourceAdapter đọc tocApi và withSearch giữ lại', () {
    final a = SourceAdapter.fromJson({
      'domain': 'truyendich.space',
      'tocApi': {
        'novelUrl': 'https://x.com/api/novels/{slug}',
        'listUrl': 'https://x.com/api/novels/{slug}/chapters?page={page}',
        'chapterUrl': 'https://x.com/doc-truyen/{slug}/chuong-{number}',
      },
    });
    expect(a.tocApi, isNotNull);
    expect(a.tocApi!.listUrl, contains('{page}'));
    final b = a.withSearch('https://x.com/s?q={query}', {});
    expect(b.tocApi, same(a.tocApi));
    final none = SourceAdapter.fromJson({'domain': 'x.com'});
    expect(none.tocApi, null);
  });

  test('slugOf lấy segment cuối của URL truyện', () {
    expect(
      WebFetcher.slugOf('https://truyendich.space/doc-truyen/kiem-chi-du-hiep'),
      'kiem-chi-du-hiep',
    );
    expect(WebFetcher.slugOf('https://x.com/'), '');
  });

  test('chaptersFromApi gộp trang, khử trùng lặp, sort theo số', () {
    final pages = [
      {
        'total': 3,
        'items': [
          {'chapter_number': 2, 'title': 'C2'},
          {'chapter_number': 1, 'title': 'C1'},
        ],
      },
      {
        'total': 3,
        'items': [
          {'chapter_number': 2, 'title': 'C2 trùng'},
          {'chapter_number': 3, 'title': ''},
        ],
      },
    ];
    final cs = WebFetcher.chaptersFromApi(
      pages,
      'https://x.com/doc-truyen/{slug}/chuong-{number}',
      'truyen-a',
    );
    expect(cs.map((c) => c.url).toList(), [
      'https://x.com/doc-truyen/truyen-a/chuong-1',
      'https://x.com/doc-truyen/truyen-a/chuong-2',
      'https://x.com/doc-truyen/truyen-a/chuong-3',
    ]);
    expect(cs[1].title, 'C2');
    expect(cs[2].title, 'Chương 3');
    expect(WebFetcher.chaptersFromApi([{'items': []}], 'u{number}', 's'), isEmpty);
  });

  test('novelFromApi resolve ảnh bìa tương đối, bỏ title trống', () {
    final chapters = [ChapterRef(title: 'C1', url: 'https://x.com/chuong-1')];
    final info = WebFetcher.novelFromApi(
      {'title': 'Truyện A', 'image_url': '/anh-bia/a.webp?v=1'},
      chapters,
      Uri.parse('https://x.com/api/novels/truyen-a'),
    );
    expect(info!.title, 'Truyện A');
    expect(info.coverUrl, 'https://x.com/anh-bia/a.webp?v=1');
    expect(
      WebFetcher.novelFromApi({'title': ' '}, chapters, Uri.parse('https://x.com')),
      null,
    );
    final noCover = WebFetcher.novelFromApi(
      {'title': 'T'},
      chapters,
      Uri.parse('https://x.com'),
    );
    expect(noCover!.coverUrl, null);
  });
}