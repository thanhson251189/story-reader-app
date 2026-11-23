import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/chapter_prefetcher.dart';
import 'package:story_reader/reader/reader_fonts.dart';
import 'package:story_reader/reader/reader_screen.dart';
import 'package:story_reader/tts/tts_player.dart';

void main() {
  test('id lạ hoặc rỗng coi như font máy, không trỏ family thiếu', () {
    expect(ReaderFonts.byId(null).id, ReaderFonts.systemId);
    expect(ReaderFonts.byId('').id, ReaderFonts.systemId);
    expect(ReaderFonts.byId('comic-sans').id, ReaderFonts.systemId);
    expect(ReaderFonts.familyOf(null), isNull);
    expect(ReaderFonts.familyOf('comic-sans'), isNull);
    expect(ReaderFonts.familyOf('literata'), 'Literata');
    expect(ReaderFonts.familyOf('beVietnam'), 'BeVietnamPro');
  });

  test('mỗi font nhúng có file và được khai trong pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(File('assets/fonts/OFL.txt').existsSync(), isTrue);
    for (final font in ReaderFonts.options) {
      final family = font.family;
      if (family == null) continue;
      expect(pubspec, contains('family: $family'), reason: family);
      for (final weight in ['Regular', 'Bold']) {
        final file = File('assets/fonts/$family-$weight.ttf');
        expect(file.existsSync(), isTrue, reason: file.path);
        expect(file.lengthSync(), greaterThan(1000), reason: file.path);
      }
    }
  });

  testWidgets('font đã lưu áp vào chữ chương; chọn font khác thì đổi và lưu', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1200);
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
    db.settings[ReaderFonts.settingKey] = 'literata';
    const url = 'book:demo:0';
    db.cache[url] = ChapterContent(
      url: url,
      title: 'Chương thử',
      paragraphs: const ['Ánh trăng sáng trên sông.'],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          ttsPlayerProvider.overrideWithValue(_FakeTtsPlayer()),
          chapterPrefetcherProvider.overrideWithValue(_NoopPrefetcher()),
        ],
        child: MaterialApp(
          navigatorObservers: [routeObserver],
          home: const ReaderScreen(url: url),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_paragraph(tester).style?.fontFamily, 'Literata');

    await tester.tap(find.byTooltip('Thêm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cài đặt đọc'));
    await tester.pumpAndSettle();
    expect(find.text('Font chữ: Literata'), findsOneWidget);

    await tester.tap(find.text('Be Vietnam Pro'));
    await tester.pumpAndSettle();

    expect(db.settings[ReaderFonts.settingKey], 'beVietnam');
    expect(_paragraph(tester).style?.fontFamily, 'BeVietnamPro');
    expect(find.text('Font chữ: Be Vietnam Pro'), findsOneWidget);
  });

  testWidgets('id font hỏng trong máy không làm vỡ màn đọc', (tester) async {
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
    db.settings[ReaderFonts.settingKey] = 'không-có-font-này';
    const url = 'book:demo:0';
    db.cache[url] = ChapterContent(
      url: url,
      title: 'Chương thử',
      paragraphs: const ['Ánh trăng sáng trên sông.'],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          ttsPlayerProvider.overrideWithValue(_FakeTtsPlayer()),
          chapterPrefetcherProvider.overrideWithValue(_NoopPrefetcher()),
        ],
        child: const MaterialApp(home: ReaderScreen(url: url)),
      ),
    );
    await tester.pumpAndSettle();
    expect(_paragraph(tester).style?.fontFamily, isNull);
    expect(find.text('Ánh trăng sáng trên sông.'), findsOneWidget);
  });
}

Text _paragraph(WidgetTester tester) =>
    tester.widget<Text>(find.text('Ánh trăng sáng trên sông.'));

class _FakeAppDb extends AppDb {
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
  Future<ChapterContent> fillNav(ChapterContent c) async => c;

  @override
  Future<void> cacheChapter(ChapterContent c, {bool touchFetchedAt = true}) async {
    cache[c.url] = c;
  }

  @override
  Future<ChapterContent> fixWords(ChapterContent c, {String? storyUrl}) async =>
      c;

  @override
  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {}

  @override
  Future<bool> isInLibrary(String storyUrl) async => false;

  @override
  Future<double?> getPosition(String url) async => null;

  @override
  Future<void> savePosition(String url, double offset) async {}

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async => const [];

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
