import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/chapter_prefetcher.dart';
import 'package:story_reader/reader/reader_screen.dart';
import 'package:story_reader/tts/tts_player.dart';

void main() {
  setUpAll(() async {
    // Font test mặc định (Ahem) rộng bằng cỡ chữ nên đo chật/hẹp sai; nạp
    // font thật của app dưới tên Roboto như trên máy.
    final loader = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/BeVietnamPro-Regular.ttf'));
    await loader.load();
  });

  test('số chương đọc từ đầu tiêu đề', () {
    expect(ReaderScreen.chapterNumberFromTitle('Chương 12: Thiên Hải'), 12);
    expect(ReaderScreen.chapterNumberFromTitle('chương 1234'), 1234);
    expect(ReaderScreen.chapterNumberFromTitle('Chapter 5 - Mở đầu'), 5);
    expect(ReaderScreen.chapterNumberFromTitle('Hồi 7'), 7);
    expect(ReaderScreen.chapterNumberFromTitle('Chương thử'), isNull);
    expect(ReaderScreen.chapterNumberFromTitle('Ngoại truyện 3'), isNull);
  });

  test('tên chương bỏ phần số đã hiện riêng', () {
    expect(ReaderScreen.chapterRest('Chương 12: Thiên Hải'), 'Thiên Hải');
    expect(ReaderScreen.chapterRest('Chương 12'), '');
    expect(ReaderScreen.chapterRest('Chương 12. Thiên Hải'), 'Thiên Hải');
    expect(ReaderScreen.chapterRest('Chương thử'), 'Chương thử');
  });

  testWidgets('chữ hệ thống 1.6: thanh dưới vẫn hiện đủ số chương', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('story_reader/volume_keys'),
      (call) async => null,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('story_reader/volume_keys'),
        null,
      ),
    );

    final db = _FakeAppDb();
    const url = 'https://x.test/truyen/a/chuong-1234';
    db.cache[url] = ChapterContent(
      url: url,
      title: 'Chương 1234: Thiên Hải Quan Vụ',
      paragraphs: const ['Một đoạn văn.'],
    );
    db.toc = [
      for (var i = 1; i <= 1350; i++)
        ChapterRef(title: 'Chương $i', url: 'https://x.test/truyen/a/chuong-$i'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          ttsPlayerProvider.overrideWithValue(_FakeTtsPlayer()),
          chapterPrefetcherProvider.overrideWithValue(_NoopPrefetcher()),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.6)),
              child: const ReaderScreen(url: url),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('1234/1350'), findsWidgets);
    expect(find.text('Thiên Hải Quan Vụ'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}

class _FakeAppDb extends AppDb {
  final settings = <String, String>{};
  final cache = <String, ChapterContent>{};
  List<ChapterRef> toc = [];

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<ChapterContent?> getCachedChapter(String url) async => cache[url];

  @override
  Future<ChapterContent> fillNav(ChapterContent c) async => c;

  @override
  Future<void> cacheChapter(
    ChapterContent c, {
    bool touchFetchedAt = true,
  }) async {
    cache[c.url] = c;
  }

  @override
  Future<ChapterContent> fixWords(
    ChapterContent c, {
    String? storyUrl,
  }) async => c;

  @override
  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {}

  @override
  Future<bool> isInLibrary(String storyUrl) async => false;

  @override
  Future<double?> getPosition(String url) async => null;

  @override
  Future<void> savePosition(String url, double offset) async {}

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async => toc;

  @override
  Future<int> webCacheCount() async => 0;

  @override
  Future<int> pinnedWebCount() async => 0;
}

class _FakeTtsPlayer extends ChangeNotifier implements TtsPlayer {
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
  double rate = 1.0;
  @override
  double pitch = 1.0;
  @override
  bool keepScreenOn = false;
  @override
  List<Map<String, String>> voices = [];
  @override
  Map<String, String>? currentVoice;
  @override
  List<SpeakChunk> chunks = [];
  @override
  int currentParaIndex = 0;

  @override
  List<Map<String, String>> get viVoices => const [];

  @override
  Future<void> setPitch(double v) async => pitch = v;

  @override
  Future<void> setRate(double v) async => rate = v;

  @override
  Future<void> setKeepScreenOn(bool v) async => keepScreenOn = v;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _NoopPrefetcher implements ChapterPrefetcher {
  @override
  Future<void> prefetch(String? startUrl) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
