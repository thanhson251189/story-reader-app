import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/reader/toc_screen.dart';

class FakeAppDb extends AppDb {
  final toc = <String, List<ChapterRef>>{};
  final cachedUrls = <String>{};

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async =>
      toc[storyUrl] ?? [];

  @override
  Future<Set<String>> getCachedChapterUrls() async => cachedUrls;
}

void main() {
  const storyUrl = 'https://x.test/doc-truyen/truyen';
  late FakeAppDb db;

  setUp(() {
    db = FakeAppDb();
    db.toc[storyUrl] = [
      for (var i = 1; i <= 1000; i++)
        ChapterRef(title: 'Chương $i', url: '$storyUrl/chuong-$i'),
    ];
  });

  Future<void> pumpToc(WidgetTester tester, String? currentUrl) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appDbProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: TocScreen(storyUrl: storyUrl, currentChapterUrl: currentUrl),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double pixels(WidgetTester tester) =>
      tester.widget<ListView>(find.byType(ListView)).controller!.position.pixels;

  testWidgets('mục lục tự cuộn tới chương đang đọc', (tester) async {
    await pumpToc(tester, '$storyUrl/chuong-500');
    // Dòng 499 (index 0-based) lùi lên 2 dòng: (499 - 2) * 48.
    expect(pixels(tester), (499 - 2) * 48.0);
    expect(find.text('Chương 500'), findsOneWidget);
  });

  testWidgets('URL lệch dấu slash cuối vẫn tìm đúng chương', (tester) async {
    await pumpToc(tester, '$storyUrl/chuong-500/');
    expect(pixels(tester), (499 - 2) * 48.0);
  });

  testWidgets('URL dính fragment # vẫn tìm đúng chương', (tester) async {
    await pumpToc(tester, '$storyUrl/chuong-500#');
    expect(pixels(tester), (499 - 2) * 48.0);
  });

  testWidgets('khác http/https vẫn tìm đúng chương', (tester) async {
    await pumpToc(tester, 'http://x.test/doc-truyen/truyen/chuong-500');
    expect(pixels(tester), (499 - 2) * 48.0);
  });
}