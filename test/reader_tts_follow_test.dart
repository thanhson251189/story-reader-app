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

class FakeAppDb extends AppDb {
  final settings = <String, String>{};
  final positions = <String, double>{};
  final cache = <String, ChapterContent>{};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<void> savePosition(String url, double offset) async {
    positions[url] = offset;
  }

  @override
  Future<double?> getPosition(String url) async => positions[url];

  @override
  Future<ChapterContent?> getCachedChapter(String url) async => cache[url];

  @override
  Future<void> cacheChapter(ChapterContent c) async {
    cache[c.url] = c;
  }

  @override
  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {}
}

class FakeTtsPlayer extends ChangeNotifier implements TtsPlayer {
  @override
  ChapterContent? chapter;
  @override
  bool playing = false;
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

  void emit() => notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class NoopPrefetcher implements ChapterPrefetcher {
  @override
  Future<void> prefetch(String? startUrl) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ChapterContent chapter(int i) => ChapterContent(
  url: 'https://x.test/c/$i',
  title: 'Chương $i',
  paragraphs: List.generate(40, (j) => 'Đoạn $j của chương $i. ' * 6),
  nextUrl: i < 4 ? 'https://x.test/c/${i + 1}' : null,
  prevUrl: i > 1 ? 'https://x.test/c/${i - 1}' : null,
);

void main() {
  late FakeAppDb db;
  late FakeTtsPlayer player;

  setUp(() {
    db = FakeAppDb();
    for (var i = 1; i <= 4; i++) {
      db.cache[chapter(i).url] = chapter(i);
    }
    player = FakeTtsPlayer();
  });

  Future<void> pumpReader(WidgetTester tester, String url) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('story_reader/volume_keys'),
      (call) async => null,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          ttsPlayerProvider.overrideWithValue(player),
          chapterPrefetcherProvider.overrideWithValue(NoopPrefetcher()),
        ],
        child: MaterialApp(
          navigatorObservers: [routeObserver],
          home: ReaderScreen(url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('TTS pause ở chương cũ không kéo reader lùi chương', (
    tester,
  ) async {
    await pumpReader(tester, 'https://x.test/c/4');
    expect(find.text('Chương 4'), findsWidgets);

    // Trước đó nghe tới chương 2 rồi pause, đọc tay tiếp lên chương 4.
    player.chapter = chapter(2);
    player.playing = false;
    // Notify không liên quan tới phát (vd: hẹn giờ tắt fires, đổi giọng...).
    player.emit();
    await tester.pumpAndSettle();

    expect(find.text('Chương 4'), findsWidgets);
    expect(find.text('Chương 2'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('TTS đang phát chuyển chương thì reader đi theo', (tester) async {
    await pumpReader(tester, 'https://x.test/c/4');
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 700));
    expect(db.positions['https://x.test/c/4'], greaterThan(0));

    player.chapter = chapter(3);
    player.playing = true;
    player.emit();
    await tester.pumpAndSettle();

    expect(find.text('Chương 3'), findsWidgets);
    expect(find.text('Chương 4'), findsNothing);
    await tester.pump(const Duration(seconds: 1));
  });
}