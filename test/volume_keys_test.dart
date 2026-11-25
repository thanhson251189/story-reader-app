import 'dart:async';

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
  final toc = <String, List<ChapterRef>>{};

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
  Future<int?> chapterFetchedAt(String url) async => null;

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async =>
      toc[storyUrl] ?? const [];

  @override
  Future<void> cacheChapter(
    ChapterContent c, {
    bool touchFetchedAt = true,
  }) async {
    cache[c.url] = c;
  }

  @override
  Future<ChapterContent> fillNav(ChapterContent c) async => c;

  @override
  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {}

  @override
  Future<bool> isInLibrary(String storyUrl) async => false;
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
  Future<void> start(
    ChapterContent c, {
    int paraIndex = 0,
    String? storyUrl,
    String? storyTitle,
  }) async {}

  @override
  Future<void> stop() async {}

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

/// Nhấn phím âm lượng: native gửi sự kiện xuống channel như thật. Bắn qua
/// handlePlatformMessage để đi đúng đường đăng ký handler của màn đọc.
void pressVolumeDown() {
  const channel = MethodChannel('story_reader/volume_keys');
  const codec = StandardMethodCodec();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(const MethodCall('volumeKey', 'down')),
        (_) {},
      );
}

void main() {
  testWidgets(
    'Back về màn đọc cũ từ màn đọc đè lên thì phím âm lượng vẫn lật trang',
    (tester) async {
      final db = FakeAppDb();
      db.cache[chapter(1).url] = chapter(1);
      db.cache[chapter(2).url] = chapter(2);
      final player = FakeTtsPlayer();
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
            home: ReaderScreen(url: chapter(1).url),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chương 1'), findsWidgets);

      // Mục lục mở chương mới: một màn đọc thứ hai đè lên màn đọc cũ (cùng
      // hiệu ứng với pushReplacement từ mục lục). KHÔNG await push — future của
      // nó chỉ hoàn tất khi route được pop, await là treo test.
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute(builder: (_) => ReaderScreen(url: chapter(2).url)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Chương 2'), findsWidgets);

      // Quay về màn đọc cũ: dispose màn đọc trên xoá handler chung của channel —
      // màn đọc dưới phải đăng ký lại trong didPopNext.
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Chương 1'), findsWidgets);

      // Nhấn phím âm lượng: phải lật trang (vị trí cuộn đổi và được lưu).
      pressVolumeDown();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 700));
      expect(
        db.positions[chapter(1).url] ?? 0,
        greaterThan(0),
        reason: 'phím âm lượng phải lật trang màn đọc dưới sau khi quay về',
      );
    },
  );
}
