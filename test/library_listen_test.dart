import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/library/library_screen.dart';
import 'package:story_reader/tts/tts_player.dart';

class _FakeDb extends AppDb {
  final settings = <String, String>{};
  List<Map<String, dynamic>> library = const [];

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<List<Map<String, dynamic>>> getLibrary() async => library;

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async => const [];

  @override
  Future<Map<String, int>> tocCountByStory() async => const {};
}

class _FakeTts extends ChangeNotifier implements TtsPlayer {
  String? url;
  String? story;
  String? title;

  @override
  Future<bool> playChapter(
    String url, {
    String? storyUrl,
    String? storyTitle,
    int paraIndex = 0,
  }) async {
    this.url = url;
    story = storyUrl;
    title = storyTitle;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('sách trong máy: menu có Nghe và mở đúng chương trong cache', (
    tester,
  ) async {
    final db = _FakeDb();
    db.library = [
      {
        'story_url': 'book:b1',
        'title': 'Sách mới nhập',
        'last_chapter_url': null,
      },
    ];
    final tts = _FakeTts();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          adapterRepoProvider.overrideWithValue(AdapterRepository([])),
          ttsPlayerProvider.overrideWithValue(tts),
        ],
        child: MaterialApp(home: LibraryScreen(active: true)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Sách mới nhập'));
    await tester.pumpAndSettle();
    expect(find.text('Nghe từ chương đang đọc'), findsOneWidget);
    // Các mục chỉ dành cho nguồn web vẫn phải ẩn với sách trong máy.
    expect(find.text('Tải cả truyện'), findsNothing);
    expect(find.text('Xoá chương đã tải'), findsNothing);
    expect(find.text('Kiểm tra chương mới'), findsNothing);

    await tester.tap(find.text('Nghe từ chương đang đọc'));
    await tester.pumpAndSettle();

    // Thiếu last_chapter_url thì rơi về chương đầu, không truyền book:<id> trơn.
    expect(tts.url, 'book:b1:0');
    expect(tts.story, 'book:b1');
  });
}
