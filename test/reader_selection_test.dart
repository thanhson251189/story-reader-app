import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/chapter_prefetcher.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/reader/reader_screen.dart';
import 'package:story_reader/tts/tts_player.dart';

/// Test bôi đen text ở màn đọc (SelectionArea) → menu Copy/Đổi từ/Dịch.
/// DB giả (đè các hàm cần thiết) nên toàn bộ chạy trong fake-async thuần,
/// không cần runAsync như test dùng DB thật.
class FakeAppDb extends AppDb {
  final settings = <String, String>{};
  final cache = <String, ChapterContent>{};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<ChapterContent?> getCachedChapter(String url) async => cache[url];

  @override
  Future<int?> chapterFetchedAt(String url) async => null;

  @override
  Future<void> cacheChapter(ChapterContent c) async {
    cache[c.url] = c;
  }

  @override
  Future<ChapterContent> fillNav(ChapterContent c) async => c;

  @override
  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {}

  @override
  Future<void> savePosition(String url, double offset) async {}

  @override
  Future<double?> getPosition(String url) async => null;

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async => const [];

  // ---- Đánh dấu đoạn (giả, trong bộ nhớ) ----
  int _bookmarkId = 0;
  final List<Map<String, dynamic>> _bookmarkRows = [];

  @override
  Future<bool> toggleBookmark({
    required String storyUrl,
    required String chapterUrl,
    required String chapterTitle,
    required int paraIndex,
    required String snippet,
  }) async {
    bool same(Map<String, dynamic> b) =>
        b['story_url'] == storyUrl &&
        b['chapter_url'] == chapterUrl &&
        b['para_index'] == paraIndex;
    final existed = _bookmarkRows.any(same);
    _bookmarkRows.removeWhere(same);
    if (existed) return false;
    _bookmarkRows.add({
      'id': ++_bookmarkId,
      'story_url': storyUrl,
      'chapter_url': chapterUrl,
      'chapter_title': chapterTitle,
      'para_index': paraIndex,
      'snippet': snippet,
      'created_at': _bookmarkId,
    });
    return true;
  }

  @override
  Future<List<Map<String, dynamic>>> getBookmarks(String storyUrl) async {
    final rows =
        [
          for (final b in _bookmarkRows)
            if (b['story_url'] == storyUrl) Map<String, dynamic>.from(b),
        ]..sort(
          (a, b) => (b['created_at'] as int).compareTo(a['created_at'] as int),
        );
    return rows;
  }

  @override
  Future<void> removeBookmark(int id) async {
    _bookmarkRows.removeWhere((b) => b['id'] == id);
  }
}

class FakeTtsPlayer extends ChangeNotifier implements TtsPlayer {
  @override
  ChapterContent? chapter;
  @override
  bool playing = false;
  @override
  bool loading = false;
  @override
  String? lastError;
  @override
  DateTime? sleepAt;
  @override
  List<SpeakChunk> chunks = [];
  @override
  int get currentParaIndex => -1;
  @override
  SpeakChunk? get currentChunk => null;

  @override
  Future<void> start(ChapterContent c, {int paraIndex = 0}) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> skipPrev() async {}

  @override
  Future<void> skipNext() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NoopPrefetcher implements ChapterPrefetcher {
  @override
  Future<void> prefetch(String? startUrl) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> pumpReader(
  WidgetTester tester,
  AppDb db, {
  int? initialParagraph,
}) async {
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('story_reader/volume_keys'),
    (call) async => null,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDbProvider.overrideWithValue(db),
        ttsPlayerProvider.overrideWithValue(FakeTtsPlayer()),
        chapterPrefetcherProvider.overrideWithValue(NoopPrefetcher()),
        adapterRepoProvider.overrideWithValue(AdapterRepository([])),
        webFetcherProvider.overrideWithValue(WebFetcher()),
      ],
      child: MaterialApp(
        home: ReaderScreen(
          url: 'https://x.test/c/1',
          initialParagraph: initialParagraph,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Bôi đen text → menu Copy/Đổi từ/Dịch hiện đủ', (tester) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: ['Hắn gi ết người rồi bỏ trốn.', 'Đoạn hai bình thường.'],
    );
    await pumpReader(tester, db);

    await tester.longPress(find.textContaining('gi ết'));
    await tester.pumpAndSettle();

    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Đổi từ'), findsOneWidget);
    expect(find.text('Dịch'), findsOneWidget);
    expect(find.text('Đánh dấu'), findsOneWidget);

    // Menu dọc nằm DƯỚI chỗ bôi đen (không đè lên vùng chọn), không phải ở
    // đáy màn như bản cũ.
    final press = tester.getCenter(find.textContaining('gi ết'));
    final menu = tester.getRect(find.byKey(const Key('selection_menu')));
    // ignore: avoid_print
    print('DEBUG press=$press menu=$menu');
    expect(menu.top, greaterThan(press.dy), reason: 'menu đè lên vùng chọn');
    expect(
      (menu.center - press).distance,
      lessThan(240),
      reason: 'menu lệch xa chỗ chọn: press=$press menu=$menu',
    );
  });

  testWidgets('Cuộn sâu xuống giữa chương dài, nhấn giữ vẫn hiện menu', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: List.generate(40, (j) => 'Đoạn số $j. ' * 8),
    );
    await pumpReader(tester, db);

    // Cuộn tới giữa chương như người dùng đọc tới đoạn sâu.
    await tester.fling(
      find.byType(SingleChildScrollView),
      const Offset(0, -2000),
      1000,
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.textContaining('Đoạn số 20'));
    await tester.pumpAndSettle();

    // Thanh lệnh hiện ở đáy màn, độc lập với vị trí cuộn.
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Đổi từ'), findsOneWidget);
    expect(find.text('Dịch'), findsOneWidget);
  });

  testWidgets('Đổi từ: hộp thoại điền sẵn, lưu xong chương áp ngay', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: ['Hắn gi ết người rồi bỏ trốn.', 'Đoạn hai bình thường.'],
    );
    await pumpReader(tester, db);
    expect(find.text('Hắn gi ết người rồi bỏ trốn.'), findsOneWidget);

    await tester.longPress(find.textContaining('gi ết'));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(
      'DEBUG bubble=${tester.getRect(find.byKey(const Key('selection_menu')))}',
    );
    // ignore: avoid_print
    print('DEBUG doi_tu=${tester.getRect(find.text('Đổi từ'))}');
    await tester.tap(find.text('Đổi từ'));
    await tester.pumpAndSettle();
    // ignore: avoid_print
    print(
      'DEBUG bubble_sau=${find.byKey(const Key('selection_menu')).evaluate().isNotEmpty ? tester.getRect(find.byKey(const Key('selection_menu'))) : 'gone'}',
    );
    // Hộp thoại sửa lỗi mở với cụm từ sai điền sẵn text vừa bôi đen.
    expect(find.text('Thêm cụm từ'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), 'gi ết');
    await tester.enterText(find.byType(TextField).at(1), 'giết');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();

    // Chương đang mở áp bản sửa NGAY (không phải mở lại chương), và cặp
    // cụm từ đã vào DB để các lần mở sau dùng chung. Bỏ chọn xong thanh
    // lệnh cũng tự ẩn.
    expect(find.text('Hắn giết người rồi bỏ trốn.'), findsOneWidget);
    expect(find.text('Hắn gi ết người rồi bỏ trốn.'), findsNothing);
    expect(await db.getWordFixes(), contains(('gi ết', 'giết')));
    expect(find.text('Copy'), findsNothing);
  });

  testWidgets('Mở tìm kiếm: sheet hiện ngay trên bàn phím, không bị trùm', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: ['Đoạn một có chữ cần tìm.', 'Đoạn hai bình thường.'],
    );
    await pumpReader(tester, db);

    // Giả bàn phím chiếm 300px LOGICAL đáy màn (FakeViewPadding tính theo
    // pixel vật lý nên phải nhân devicePixelRatio) như trên máy thật lúc ô
    // nhập có focus.
    tester.view.viewInsets = FakeViewPadding(
      bottom: 300 * tester.view.devicePixelRatio,
    );
    addTearDown(tester.view.resetViewInsets);

    await tester.tap(find.byTooltip('Tìm trong chương'));
    await tester.pumpAndSettle();

    // Sheet phải hiện đủ phần nhập + gợi ý NGAY khi mở, nằm trên bàn phím
    // (bug đã gặp: sheet không nhính theo viewInsets nên bị trùm hết).
    expect(find.text('Nhập từ khoá để tìm trong chương'), findsOneWidget);
    final hint = tester.getRect(find.text('Nhập từ khoá để tìm trong chương'));
    final screenH =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      hint.bottom,
      lessThan(screenH - 300),
      reason: 'sheet bị bàn phím đè: $hint',
    );
  });

  testWidgets('Kết quả tìm kiếm tô màu phần khớp từ khoá', (tester) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: ['Đoạn một có chữ cần tìm.', 'Đoạn hai bình thường.'],
    );
    await pumpReader(tester, db);

    await tester.tap(find.byTooltip('Tìm trong chương'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'cần');
    await tester.pumpAndSettle();

    expect(find.text('1 đoạn khớp'), findsOneWidget);

    // Tiêu đề kết quả là Text.rich với span "cần" mang nền tô màu.
    final tile = tester
        .widgetList<Text>(
          find.byWidgetPredicate((w) => w is Text && w.textSpan != null),
        )
        .where((t) => t.textSpan!.toPlainText().contains('Đoạn một'))
        .single;
    final spans = (tile.textSpan! as TextSpan).children!.cast<TextSpan>();
    final highlighted = [
      for (final s in spans)
        if (s.style?.backgroundColor != null) s.text,
    ];
    expect(highlighted, ['cần']);
  });

  testWidgets('Đánh dấu đoạn: lưu DB, vào danh sách, xoá được', (tester) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: ['Hắn gi ết người rồi bỏ trốn.', 'Đoạn hai bình thường.'],
    );
    await pumpReader(tester, db);

    await tester.longPress(find.textContaining('gi ết'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đánh dấu'));
    await tester.pumpAndSettle();

    // Đã lưu + snackbar xác nhận; menu thu lại sau khi chọn.
    expect(find.text('Đã đánh dấu đoạn 1'), findsOneWidget);
    expect(find.text('Copy'), findsNothing);
    final marks = await db.getBookmarks('https://x.test/c');
    expect(marks.length, 1);
    expect(marks.single['para_index'], 0);

    // Danh sách đánh dấu: snippet + nhãn chương/đoạn.
    await tester.tap(find.byTooltip('Đoạn đã đánh dấu'));
    await tester.pumpAndSettle();
    expect(find.text('Đoạn đã đánh dấu'), findsOneWidget);
    expect(find.textContaining('Hắn gi ết người'), findsNWidgets(2));
    expect(find.text('Chương 1 · Đoạn 1'), findsOneWidget);

    // Xoá đánh dấu khỏi danh sách → DB rỗng, sheet báo rỗng.
    await tester.tap(find.byTooltip('Xoá đánh dấu'));
    await tester.pumpAndSettle();
    expect(await db.getBookmarks('https://x.test/c'), isEmpty);
    expect(find.textContaining('Chưa có đoạn nào'), findsOneWidget);
  });

  testWidgets('Bấm dòng đánh dấu cùng chương: nhảy tới đoạn, sheet đóng', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: List.generate(40, (j) => 'Đoạn số $j. ' * 8),
    );
    await db.toggleBookmark(
      storyUrl: 'https://x.test/c',
      chapterUrl: 'https://x.test/c/1',
      chapterTitle: 'Chương 1',
      paraIndex: 30,
      snippet: 'Đoạn số 30.',
    );
    await pumpReader(tester, db);

    await tester.tap(find.byTooltip('Đoạn đã đánh dấu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chương 1 · Đoạn 31'));
    await tester.pumpAndSettle();

    // Sheet đóng, chương cuộn tới đoạn 30 (nháy sáng đang bật).
    expect(find.text('Đoạn đã đánh dấu'), findsNothing);
    final r = tester.getRect(find.textContaining('Đoạn số 30. '));
    expect(r.top, lessThan(300), reason: 'không cuộn tới đoạn 30: $r');
  });

  testWidgets('Mở màn với initialParagraph: nhảy thẳng tới đoạn', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.cache['https://x.test/c/1'] = ChapterContent(
      url: 'https://x.test/c/1',
      title: 'Chương 1',
      paragraphs: List.generate(40, (j) => 'Đoạn số $j. ' * 8),
    );
    await pumpReader(tester, db, initialParagraph: 25);

    final r = tester.getRect(find.textContaining('Đoạn số 25. '));
    expect(r.top, lessThan(300), reason: 'không nhảy tới đoạn 25: $r');
  });
}
