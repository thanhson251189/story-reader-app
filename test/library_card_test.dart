import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/library/library_screen.dart';

const _story =
    'https://truyendich.vn/kiem-dao-de-nhat-tien-ban-dich-chuan-full/';

List<ChapterRef> tocChapters(int count) => [
  for (var i = 1; i <= count; i++)
    ChapterRef(title: 'Chương $i', url: '${_story}chuong-$i/'),
];

class FakeAppDb extends AppDb {
  final List<Map<String, dynamic>> library;
  final Map<String, List<ChapterRef>> tocs = {};
  final Map<String, String> settings = {};

  FakeAppDb(this.library, {int tocCount = 0, String tocStory = _story}) {
    if (tocCount > 0) tocs[tocStory] = tocChapters(tocCount);
  }

  @override
  Future<List<Map<String, dynamic>>> getLibrary() async => library;

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async =>
      tocs[storyUrl] ?? const [];

  @override
  Future<bool> saveTocUnlessShorter(String storyUrl, NovelInfo info) async {
    if (!info.tocComplete || info.chapters.isEmpty) return false;
    final cur = tocs[storyUrl] ?? const <ChapterRef>[];
    if (cur.length > info.chapters.length) return false;
    tocs[storyUrl] = info.chapters;
    return true;
  }

  @override
  Future<void> setLatestChapter(
    String storyUrl,
    String url,
    String title,
  ) async {
    for (var i = 0; i < library.length; i++) {
      if (library[i]['story_url'] == storyUrl) {
        library[i] = {
          ...library[i],
          'latest_chapter_url': url,
          'latest_chapter_title': title,
        };
      }
    }
  }
}

class FakeFetcher extends WebFetcher {
  final NovelInfo info;
  FakeFetcher(this.info);

  @override
  Future<NovelInfo> fetchStory(
    String url,
    SourceAdapter adapter, {
    int maxTries = 8,
  }) async => info;
}

Map<String, dynamic> item({
  required String storyUrl,
  required String title,
  String? last,
  String? latest,
  String? latestTitle,
}) => {
  'story_url': storyUrl,
  'title': title,
  'cover_url': null,
  'last_chapter_url': last,
  'latest_chapter_url': latest,
  'latest_chapter_title': latestTitle,
  'updated_at': 1,
};

Future<void> pumpLibrary(
  WidgetTester tester,
  AppDb db, {
  AdapterRepository? adapters,
  WebFetcher? fetcher,
}) async {
  tester.view.physicalSize = const Size(1080, 2412);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDbProvider.overrideWithValue(db),
        adapterRepoProvider.overrideWithValue(
          adapters ?? AdapterRepository([]),
        ),
        if (fetcher != null) webFetcherProvider.overrideWithValue(fetcher),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            // Người dùng để cỡ chữ lớn — đúng ca dòng "Đang đọc" bị cắt.
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: const LibraryScreen(active: true),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // Font mặc định trong test là Ahem (mỗi ký tự rộng bằng cỡ chữ) — đo độ
    // cắt chữ sẽ sai. Nạp font thật của app dưới tên Roboto như trên máy.
    final loader = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/BeVietnamPro-Regular.ttf'));
    await loader.load();
  });

  testWidgets('Chữ to: dòng đang đọc không bị cắt, có domain nguồn', (
    tester,
  ) async {
    final db = FakeAppDb([
      item(
        storyUrl: _story,
        title: 'Kiếm Đạo Đệ Nhất',
        last: '${_story}chuong-13/',
        latest: '${_story}chuong-741/',
        latestTitle: 'Chương 741',
      ),
    ], tocCount: 741);
    await pumpLibrary(tester, db);

    final progress = find.text('Đang đọc: 13/741');
    expect(progress, findsOneWidget);
    final para = tester.renderObject<RenderParagraph>(progress);
    expect(
      para.didExceedMaxLines,
      isFalse,
      reason: 'xuống dòng được 2 dòng thay vì cắt mất số chương',
    );
    expect(find.text('truyendich.vn'), findsOneWidget);
    // Có tổng chương thì không lặp lại dòng "Chưa đọc", chỉ còn chấm nhỏ.
    expect(find.text('Chưa đọc: Chương 741'), findsNothing);
    expect(find.byKey(ValueKey('new-dot-$_story')), findsOneWidget);
    // Thẻ web có nút tuỳ chọn (nghe, tải cả truyện, kiểm tra chương mới...).
    expect(find.byTooltip('Tuỳ chọn'), findsOneWidget);
  });

  testWidgets('Sách trong máy không có domain, vẫn hiện vị trí', (
    tester,
  ) async {
    final db = FakeAppDb([
      item(storyUrl: 'book:abc', title: 'Sách nhập từ máy', last: 'book:abc:2'),
    ]);
    await pumpLibrary(tester, db);

    expect(find.text('Chương 3'), findsOneWidget);
    expect(find.text('Sách trong máy'), findsOneWidget);
  });

  testWidgets('Chưa có mục lục: vẫn hiện dòng Chưa đọc thay vì chấm', (
    tester,
  ) async {
    const story = 'https://truyendich.vn/truyen-khac/';
    final db = FakeAppDb([
      item(
        storyUrl: story,
        title: 'Truyện chưa có mục lục',
        last: '${story}chuong-5/',
        latest: '${story}chuong-9/',
        latestTitle: 'Chương 9',
      ),
    ]);
    await pumpLibrary(tester, db);

    expect(find.text('Đang đọc: 5'), findsOneWidget);
    expect(find.text('Chưa đọc: Chương 9'), findsOneWidget);
    expect(find.byKey(ValueKey('new-dot-$story')), findsNothing);
  });

  testWidgets('Chạm giữ thẻ ra menu, không xóa ngay', (tester) async {
    final db = FakeAppDb([
      item(
        storyUrl: _story,
        title: 'Kiếm Đạo Đệ Nhất',
        last: '${_story}chuong-13/',
      ),
    ]);
    await pumpLibrary(tester, db);

    await tester.longPress(find.text('Kiếm Đạo Đệ Nhất'));
    await tester.pumpAndSettle();

    expect(find.text('Đọc tiếp'), findsOneWidget);
    expect(find.text('Nghe từ chương đang đọc'), findsOneWidget);
    expect(find.text('Tải cả truyện'), findsOneWidget);
    expect(find.text('Xoá chương đã tải'), findsOneWidget);
    expect(find.text('Kiểm tra chương mới'), findsOneWidget);
    expect(find.text('Xóa khỏi thư viện'), findsOneWidget);
    expect(find.text('Kiếm Đạo Đệ Nhất'), findsOneWidget, reason: 'chưa xóa');
  });

  testWidgets('Ẩn nguồn 18+: gom truyện người lớn, bấm Hiện thì thấy lại', (
    tester,
  ) async {
    const adultStory = 'https://nguon18.test/truyen-a/';
    final db = FakeAppDb([
      item(
        storyUrl: adultStory,
        title: 'Truyện người lớn',
        last: '${adultStory}chuong-1/',
      ),
      item(
        storyUrl: _story,
        title: 'Truyện thường',
        last: '${_story}chuong-1/',
      ),
    ]);
    db.settings['hideAdult'] = '1';
    db.settings['adultDomains'] = '["nguon18.test"]';
    final adapters = AdapterRepository([
      SourceAdapter.fromJson({'domain': 'nguon18.test', 'selectors': {}}),
    ]);

    await pumpLibrary(tester, db, adapters: adapters);
    expect(find.text('Truyện người lớn'), findsNothing);
    expect(find.text('Truyện thường'), findsOneWidget);
    expect(find.text('Đã ẩn 1 truyện 18+'), findsOneWidget);

    await tester.tap(find.text('Hiện'));
    await tester.pumpAndSettle();
    expect(find.text('Truyện người lớn'), findsOneWidget);
    expect(find.text('Đang hiện 1 truyện 18+'), findsOneWidget);
  });

  testWidgets('Sách trong máy: menu không có kiểm tra chương mới', (
    tester,
  ) async {
    final db = FakeAppDb([
      item(storyUrl: 'book:abc', title: 'Sách nhập từ máy', last: 'book:abc:2'),
    ]);
    await pumpLibrary(tester, db);

    await tester.longPress(find.text('Sách nhập từ máy'));
    await tester.pumpAndSettle();

    expect(find.text('Đọc tiếp'), findsOneWidget);
    expect(find.text('Xóa khỏi thư viện'), findsOneWidget);
    expect(find.text('Kiểm tra chương mới'), findsNothing);
  });

  testWidgets('Nút kiểm tra trên thẻ báo chương mới, có nút Đọc', (
    tester,
  ) async {
    final db = FakeAppDb([
      item(
        storyUrl: _story,
        title: 'Kiếm Đạo Đệ Nhất',
        last: '${_story}chuong-13/',
        latest: '${_story}chuong-13/',
        latestTitle: 'Chương 13',
      ),
    ]);
    final info = NovelInfo(
      title: 'Kiếm Đạo Đệ Nhất',
      chapters: tocChapters(14),
    );
    final adapters = AdapterRepository([
      SourceAdapter(
        domain: 'truyendich.vn',
        version: 1,
        selectors: const {},
        removeSelectors: const [],
        textCleanup: const [],
      ),
    ]);
    await pumpLibrary(
      tester,
      db,
      adapters: adapters,
      fetcher: FakeFetcher(info),
    );

    await tester.tap(find.byTooltip('Tuỳ chọn'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kiểm tra chương mới'));
    await tester.pumpAndSettle();

    expect(find.text('Có chương mới — Chưa đọc: Chương 14'), findsOneWidget);
    expect(find.text('Đọc'), findsOneWidget, reason: 'mở luôn chương mới');
    expect(
      db.library.single['latest_chapter_url'],
      '${_story}chuong-14/',
      reason: 'mục lục và chương mới nhất được lưu',
    );
  });
}
