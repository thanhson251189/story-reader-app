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

Future<void> pumpReader(WidgetTester tester, AppDb db) async {
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
      child: const MaterialApp(home: ReaderScreen(url: 'https://x.test/c/1')),
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
    await tester.tap(find.text('Đổi từ'));
    await tester.pumpAndSettle();

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
    final screenH = tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(hint.bottom, lessThan(screenH - 300), reason: 'sheet bị bàn phím đè: $hint');
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
}
