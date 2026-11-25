import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/library/library_screen.dart';

const _story = 'https://truyendich.vn/kiem-dao-de-nhat-tien-ban-dich-chuan-full/';

class FakeAppDb extends AppDb {
  late final List<Map<String, dynamic>> library;

  FakeAppDb(this.library);

  @override
  Future<List<Map<String, dynamic>>> getLibrary() async => library;

  @override
  Future<String?> getSetting(String key) async => null;

  @override
  Future<List<ChapterRef>> getToc(String storyUrl) async {
    if (!storyUrl.contains('kiem-dao')) return const [];
    return [
      for (var i = 0; i < 741; i++)
        ChapterRef(
          title: 'Chương ${i + 1}',
          url: '${_story}chuong-${i + 1}/',
        ),
    ];
  }
}

Map<String, dynamic> item({
  required String storyUrl,
  required String title,
  String? last,
  String? latest,
  String? latestTitle,
}) => {
  'story_url': storyUrl,
  'title': title,
  'cover_url': null,
  'last_chapter_url': last,
  'latest_chapter_url': latest,
  'latest_chapter_title': latestTitle,
  'updated_at': 1,
};

Future<void> pumpLibrary(WidgetTester tester, AppDb db) async {
  tester.view.physicalSize = const Size(1080, 2412);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appDbProvider.overrideWithValue(db),
        adapterRepoProvider.overrideWithValue(AdapterRepository([])),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            // Người dùng để cỡ chữ lớn — đúng ca dòng "Đang đọc" bị cắt.
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: const LibraryScreen(active: true),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    // Font mặc định trong test là Ahem (mỗi ký tự rộng bằng cỡ chữ) — đo độ
    // cắt chữ sẽ sai. Nạp font thật của app dưới tên Roboto như trên máy.
    final loader = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/BeVietnamPro-Regular.ttf'));
    await loader.load();
  });

  testWidgets('Chữ to: dòng đang đọc không bị cắt, có domain nguồn', (
    tester,
  ) async {
    final db = FakeAppDb([
      item(
        storyUrl: _story,
        title: 'Kiếm Đạo Đệ Nhất',
        last: '${_story}chuong-13/',
        latest: '${_story}chuong-741/',
        latestTitle: 'Chương 741',
      ),
    ]);
    await pumpLibrary(tester, db);

    final progress = find.text('Đang đọc: Chương 13/741');
    expect(progress, findsOneWidget);
    final para = tester.renderObject<RenderParagraph>(progress);
    expect(
      para.didExceedMaxLines,
      isFalse,
      reason: 'xuống dòng được 2 dòng thay vì cắt mất số chương',
    );
    expect(find.text('truyendich.vn'), findsOneWidget);
    expect(find.text('Chưa đọc: Chương 741'), findsOneWidget);
  });

  testWidgets('Sách trong máy không có domain, vẫn hiện vị trí', (
    tester,
  ) async {
    final db = FakeAppDb([
      item(
        storyUrl: 'book:abc',
        title: 'Sách nhập từ máy',
        last: 'book:abc:2',
      ),
    ]);
    await pumpLibrary(tester, db);

    expect(find.text('Chương 3'), findsOneWidget);
    expect(find.text('Sách trong máy'), findsOneWidget);
  });
}
