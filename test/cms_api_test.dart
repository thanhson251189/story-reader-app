import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';

void main() {
  late HttpServer server;
  late String base;

  Map<String, dynamic> story({String? bodyFor}) => {
    'title': 'Truyện Thử',
    'cover': '/api/assets/7/content?signature=abc&proxy=1',
    'chapters': [
      {
        'slug': 'chuong-2',
        'num': 2,
        'title': 'Chương 2: Hai',
        'mediaType': 'text',
      },
      {
        'slug': 'chuong-1',
        'num': 1,
        'title': 'Chương 1: Một',
        'mediaType': 'text',
        'bodyText': bodyFor == 'chuong-1' ? 'Đoạn một.\n\nĐoạn hai.\n' : null,
      },
      {
        'slug': 'chuong-3-anh',
        'num': 3,
        'title': 'Chương 3: Ảnh',
        'mediaType': 'image',
        'pages': bodyFor == 'chuong-3-anh' ? ['/a.jpg'] : [],
      },
    ],
  };

  SourceAdapter adapter() => SourceAdapter.fromJson({
    'domain': '127.0.0.1',
    'api': {
      'searchUrl': '$base/api/stories?q={query}&page=1&perPage=30',
      'storyUrl': '$base/api/stories/{slug}',
      'chapterUrl': '$base/api/stories/{slug}/chapters/{chapter}',
      'storyPageUrl': '$base/truyen/{slug}',
      'chapterPageUrl': '$base/truyen/{slug}/chuong/{chapter}',
    },
  });

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) {
      final segs = req.uri.pathSegments;
      Object data;
      // API kiểu CMS trả application/json không kèm charset — đúng ca hay
      // làm hỏng tiếng Việt nếu đọc res.body.
      if (segs.length == 2 && segs[1] == 'stories') {
        data = [
          {
            'slug': 'truyen-chu',
            'title': 'Truyện Chữ',
            'cover': '/api/assets/8/content',
            'type': 'novel',
          },
          {'slug': 'truyen-tranh', 'title': 'Truyện Tranh', 'type': 'manga'},
        ];
      } else if (segs.length == 3) {
        data = story();
      } else {
        data = story(bodyFor: segs.last);
      }
      req.response.headers.contentType = ContentType('application', 'json');
      req.response.add(utf8.encode(jsonEncode(data)));
      req.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('SourceAdapter đọc api và withSearch giữ lại', () {
    final a = adapter();
    expect(a.api, isNotNull);
    expect(a.api!.chapterUrl, contains('{chapter}'));
    final b = a.withSearch('$base/s?q={query}', const {});
    expect(b.api, same(a.api));
    expect(SourceAdapter.fromJson({'domain': 'x.com'}).api, null);
  });

  test('templateVars lấy slug/chương, sai host trả null', () {
    final api = adapter().api!;
    expect(WebFetcher.templateVars(api.storyPageUrl, '$base/truyen/foo/'), {
      'slug': 'foo',
    });
    expect(
      WebFetcher.templateVars(
        api.chapterPageUrl,
        '$base/truyen/foo/chuong/chuong-1?x=1',
      ),
      {'slug': 'foo', 'chapter': 'chuong-1'},
    );
    expect(
      WebFetcher.templateVars(api.storyPageUrl, 'https://khac.com/truyen/foo'),
      null,
    );
  });

  test(
    'fetchStory lấy mục lục qua API, sort theo số, cover tuyệt đối',
    () async {
      final info = await WebFetcher().fetchStory('$base/truyen/foo', adapter());
      expect(info.title, 'Truyện Thử');
      expect(info.coverUrl, '$base/api/assets/7/content?signature=abc&proxy=1');
      expect(info.chapters.map((c) => c.title).toList(), [
        'Chương 1: Một',
        'Chương 2: Hai',
        'Chương 3: Ảnh',
      ]);
      expect(info.chapters.first.url, '$base/truyen/foo/chuong/chuong-1');
    },
  );

  test('fetchChapter lấy đoạn văn và chương trước/sau', () async {
    final c = await WebFetcher().fetchChapter(
      '$base/truyen/foo/chuong/chuong-1',
      adapter(),
    );
    expect(c.title, 'Chương 1: Một');
    expect(c.paragraphs, ['Đoạn một.', 'Đoạn hai.']);
    expect(c.prevUrl, null);
    expect(c.nextUrl, '$base/truyen/foo/chuong/chuong-2');
  });

  test('chương ảnh báo lỗi rõ ràng thay vì thử WebView', () async {
    expect(
      () => WebFetcher().fetchChapter(
        '$base/truyen/foo/chuong/chuong-3-anh',
        adapter(),
      ),
      throwsA(isA<ComicChapterException>()),
    );
  });

  test('searchStories dùng API, bỏ truyện tranh, giữ tiếng Việt', () async {
    final results = await WebFetcher().searchStories('truyện', adapter());
    expect(results.map((r) => r.title).toList(), ['Truyện Chữ']);
    expect(results.single.url, '$base/truyen/truyen-chu');
    expect(results.single.coverUrl, '$base/api/assets/8/content');
  });

  test('storyUrlFromChapter bỏ cả segment /chuong/ trong link', () {
    expect(
      storyUrlFromChapter('https://khotruyen.site/truyen/foo/chuong/chuong-1'),
      'https://khotruyen.site/truyen/foo',
    );
  });
}
