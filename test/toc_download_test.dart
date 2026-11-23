import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/reader/toc_screen.dart';

/// Tải trước từ mục lục: rời màn phải dừng, và chương đã có trong máy tính vào
/// đúng N chương user xin — không tải thêm cho đủ N chương mới.
class _TocDb extends AppDb {
  final toc = <String, List<ChapterRef>>{};
  final cachedUrls = <String>{};
  final pinned = <String>[];

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async => toc[storyUrl] ?? [];

  @override
  Future<Set<String>> getCachedChapterUrls() async => Set.of(cachedUrls);

  @override
  Future<Set<String>> openedChapterUrls() async => const {};

  @override
  Future<void> pinChapter(String url) async {
    pinned.add(url);
  }

  @override
  Future<void> cacheChapter(ChapterContent c) async {
    cachedUrls.add(c.url);
  }
}

class _InstantRoute<T> extends MaterialPageRoute<T> {
  _InstantRoute({required super.builder});

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;
}

class _Fetcher extends WebFetcher {
  final fetched = <String>[];

  /// Không null thì lần tải đầu chờ cổng này — mô phỏng request đang bay.
  Completer<void>? gate;

  @override
  Future<ChapterContent> fetchChapter(String url, SourceAdapter adapter) async {
    fetched.add(url);
    final g = gate;
    if (g != null && fetched.length == 1) await g.future;
    return ChapterContent(url: url, title: 't', paragraphs: const ['nội dung']);
  }
}

void main() {
  const story = 'https://x.test/truyen';
  String ch(int n) => '$story/chuong-$n';

  late _TocDb db;
  late _Fetcher fetcher;

  setUp(() {
    db = _TocDb();
    db.toc[story] = [
      for (var i = 1; i <= 8; i++) ChapterRef(title: 'Chương $i', url: ch(i)),
    ];
    fetcher = _Fetcher();
  });

  Future<void> pumpToc(WidgetTester tester, {required bool canPop}) async {
    final toc = TocScreen(storyUrl: story, currentChapterUrl: ch(1));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appDbProvider.overrideWithValue(db),
          webFetcherProvider.overrideWithValue(fetcher),
          adapterRepoProvider.overrideWithValue(
            AdapterRepository([
              SourceAdapter(
                domain: 'x.test',
                version: 1,
                selectors: const {'content': '#c'},
                removeSelectors: const [],
                textCleanup: const [],
              ),
            ]),
          ),
        ],
        child: MaterialApp(
          home: canPop
              ? Builder(
                  builder: (context) => Scaffold(
                    body: TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        _InstantRoute(builder: (_) => toc),
                      ),
                      child: const Text('Mở mục lục'),
                    ),
                  ),
                )
              : toc,
        ),
      ),
    );
    if (canPop) {
      await tester.tap(find.text('Mở mục lục'));
      await tester.pumpAndSettle();
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> tapDownload(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Tải trước chương'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tải 5 chương tiếp'));
  }

  /// Pop đúng route mục lục. pageBack chỉ pop route trên cùng — lúc menu tải
  /// còn đang đóng thì đó là menu, mục lục không dispose, vòng tải chạy tiếp.
  void leaveToc(WidgetTester tester) {
    Navigator.of(tester.element(find.byType(TocScreen)))
        .popUntil((route) => route.isFirst);
  }

  testWidgets('chương đã có trong máy tính vào 5 chương, không tải vượt', (
    tester,
  ) async {
    db.cachedUrls.addAll([ch(1), ch(2), ch(3)]);
    await pumpToc(tester, canPop: false);
    await tapDownload(tester);
    await tester.pumpAndSettle();

    expect(fetcher.fetched, [ch(4), ch(5)]);
    expect(db.pinned, containsAll([ch(1), ch(2), ch(3), ch(4), ch(5)]));
    expect(db.pinned, isNot(contains(ch(6))));
    expect(find.text('Đã xong 5 chương, tải mới 2'), findsOneWidget);
  });

  testWidgets('cả 5 chương đã có sẵn thì không tải, báo đủ', (tester) async {
    db.cachedUrls.addAll([for (var i = 1; i <= 5; i++) ch(i)]);
    await pumpToc(tester, canPop: false);
    await tapDownload(tester);
    await tester.pumpAndSettle();

    expect(fetcher.fetched, isEmpty);
    expect(db.pinned, [ch(1), ch(2), ch(3), ch(4), ch(5)]);
    expect(find.text('Đã có đủ 5 chương trong máy'), findsOneWidget);
  });

  testWidgets('rời mục lục giữa lúc đang tải thì không tải chương kế', (
    tester,
  ) async {
    fetcher.gate = Completer<void>();
    await pumpToc(tester, canPop: true);
    await tapDownload(tester);
    await tester.pump();
    expect(fetcher.fetched, [ch(1)]);

    leaveToc(tester);
    // Pop có animation: dispose (và cờ huỷ) chạy khi animation xong, không phải
    // ngay lúc pop. Phải để animation kết thúc trước khi thả request đang bay.
    await tester.pumpAndSettle();
    expect(find.byType(TocScreen), findsNothing);

    fetcher.gate!.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));

    expect(fetcher.fetched, [ch(1)]);
  });

  testWidgets(
    'rời mục lục trong lúc nghỉ giữa hai chương thì dừng trong 1 giây',
    (tester) async {
      await pumpToc(tester, canPop: true);
      await tapDownload(tester);
      await tester.pump();
      expect(fetcher.fetched, [ch(1)]);

      leaveToc(tester);
      await tester.pump();
      expect(find.byType(TocScreen), findsNothing);

      await tester.pump(const Duration(seconds: 20));

      expect(fetcher.fetched, [ch(1)]);
    },
  );

  testWidgets('bấm Huỷ trong lúc nghỉ thì không tải tiếp', (tester) async {
    await pumpToc(tester, canPop: false);
    await tapDownload(tester);
    await tester.pump();
    expect(fetcher.fetched, [ch(1)]);

    await tester.tap(find.text('Huỷ'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));

    expect(fetcher.fetched, [ch(1)]);
    expect(find.textContaining('Đã huỷ'), findsOneWidget);
  });
}
