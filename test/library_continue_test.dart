import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/library/library_screen.dart';

class FakeAppDb extends AppDb {
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
}

void main() {
  testWidgets('Thư viện có "Đọc tiếp", quay lại tab thì nạp lại vị trí mới', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.settings['lastUrl'] = 'https://x.test/truyen-cu/chuong-1';
    db.settings['lastTitle'] = 'Truyện cũ';

    Future<void> pump(bool active) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDbProvider.overrideWithValue(db),
            adapterRepoProvider.overrideWithValue(AdapterRepository([])),
          ],
          child: MaterialApp(home: LibraryScreen(active: active)),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Mở app: thẻ "Đọc tiếp" hiện truyện lúc mở app.
    await pump(true);
    expect(find.text('Đọc tiếp'), findsNothing, reason: 'không cần tiêu đề mục');
    expect(find.text('Truyện cũ'), findsOneWidget);

    // Đọc truyện khác rồi quay lại thư viện: thẻ phải đổi theo.
    db.settings['lastUrl'] = 'https://x.test/truyen-moi/chuong-9';
    db.settings['lastTitle'] = 'Truyện mới';
    await pump(false);
    await pump(true);

    expect(find.text('Truyện cũ'), findsNothing);
    expect(find.text('Truyện mới'), findsOneWidget);
  });

  test('continueLabel không hiện đường link', () {
    expect(
      LibraryScreen.continueLabel(lastUrl: 'https://x.test/truyen/chuong-1'),
      'Chương vừa đọc',
    );
    expect(
      LibraryScreen.continueLabel(
        lastUrl: 'https://x.test/truyen/chuong-9',
        savedTitle: 'Kiếm Đế',
      ),
      'Kiếm Đế',
    );
    expect(
      LibraryScreen.continueLabel(
        lastUrl: 'https://x.test/truyen/chuong-2',
        library: [
          {
            'story_url': 'https://x.test/truyen',
            'title': 'Từ thư viện',
            'last_chapter_url': 'https://x.test/truyen/chuong-2',
          },
        ],
      ),
      'Từ thư viện',
    );
    expect(
      LibraryScreen.continueLabel(lastUrl: 'book:abc:0'),
      'Sách trong máy — Chương 1',
    );
  });
}
