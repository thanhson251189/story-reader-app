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
    // cụm từ đã vào DB để các lần mở sau dùng chung.
    expect(find.text('Hắn giết người rồi bỏ trốn.'), findsOneWidget);
    expect(find.text('Hắn gi ết người rồi bỏ trốn.'), findsNothing);
    expect(await db.getWordFixes(), contains(('gi ết', 'giết')));
  });
}
