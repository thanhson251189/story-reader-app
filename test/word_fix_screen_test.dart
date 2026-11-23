import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/settings/word_fix_screen.dart';

/// Test màn quản lý từ/cụm từ sửa lỗi. DB thật qua FFI — chuỗi "ghi DB → nạp
/// lại → setState" hoàn tất theo event loop thật nên phải bọc [tester.runAsync]
/// và POLL chờ UI thật sự đổi (pumpAndSettle một mình thoát trước khi read
/// cuối kịp xong, frame setState không bao giờ được bơm).
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), 'test_word_fix_screen.db');
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  Future<void> pumpScreen(WidgetTester tester, AppDb db) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() async {
        if (i == 0) {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [appDbProvider.overrideWithValue(db)],
              child: const MaterialApp(home: WordFixScreen()),
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        // pump() thường: spinner vô hạn khiến pumpAndSettle treo đến timeout
        // (bài học cũ ở test thu gọn tìm kiếm — đừng lặp lại).
        await tester.pump(const Duration(milliseconds: 100));
      });
      // Spinner biến mất = _load nạp xong (hiện danh sách hoặc rỗng).
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('Màn không nạp xong danh sách');
  }

  /// Lặp "chờ thật + bơm frame" đến khi [ready] thoả (tối đa ~5 giây).
  /// pump() thường trong lúc chờ — pumpAndSettle chỉ gọi sau khi [ready]
  /// thoả, tránh treo vào spinner/animation vô hạn chưa kịp tắt.
  Future<void> waitUntil(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 100; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump(const Duration(milliseconds: 100));
      });
      if (ready()) {
        await tester.pumpAndSettle();
        return;
      }
    }
    fail('UI không cập nhật đúng sau thao tác');
  }

  /// Bấm mở hộp thoại thêm/sửa: chuỗi mở hộp thoại có MỘT lần đọc DB trước
  /// showDialog (showWordFixEditor nạp danh sách để kiểm tra trùng) nên tap
  /// phải chạy trong runAsync, không thì hộp thoại không bao giờ mở.
  Future<void> openEditor(WidgetTester tester, Finder tapTarget) =>
      tester.runAsync(() async {
        await tester.tap(tapTarget);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pumpAndSettle();
      });

  testWidgets('Thêm cụm từ: hiện danh sách và lưu DB', (tester) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await pumpScreen(tester, db);
    expect(find.text('Chưa có cụm từ nào'), findsOneWidget);

    await openEditor(tester, find.text('Thêm cụm từ'));
    await tester.enterText(find.byType(TextField).at(0), 'gi ết');
    await tester.enterText(find.byType(TextField).at(1), 'giết');
    await tester.tap(find.text('Lưu'));
    await waitUntil(
      tester,
      () => find.text('Chưa có cụm từ nào').evaluate().isEmpty,
    );

    expect(find.text('gi ết'), findsOneWidget);
    expect(find.textContaining('→'), findsOneWidget);
    expect(await tester.runAsync(() => db.getWordFixes()), [
      const WordFix('gi ết', 'giết'),
    ]);
  });

  testWidgets('Cụm từ trống hoặc trùng thì báo lỗi ngay trong hộp thoại', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(
      () => db.setWordFixes([const WordFix('gi ết', 'giết')]),
    );
    await pumpScreen(tester, db);

    await openEditor(tester, find.text('Thêm cụm từ'));
    // Trùng cụm từ đã có.
    await tester.enterText(find.byType(TextField).at(0), 'gi ết');
    await tester.enterText(find.byType(TextField).at(1), 'khác');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Cụm từ này đã có trong danh sách'), findsOneWidget);
    // Hộp thoại vẫn mở, chưa lưu gì thêm.
    expect(find.text('Lưu'), findsOneWidget);

    // Xoá trống cụm từ sai.
    await tester.enterText(find.byType(TextField).at(0), '   ');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Cụm từ sai không được để trống'), findsOneWidget);

    await tester.tap(find.text('Huỷ'));
    await waitUntil(tester, () => find.text('Lưu').evaluate().isEmpty);
    expect(await tester.runAsync(() => db.getWordFixes()), [
      const WordFix('gi ết', 'giết'),
    ]);
  });

  testWidgets('Bấm dòng mở hộp thoại sửa, điền sẵn giá trị cũ', (tester) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(
      () => db.setWordFixes([const WordFix('thi th ể', 'thi thể')]),
    );
    await pumpScreen(tester, db);

    await openEditor(tester, find.text('thi th ể'));
    await tester.enterText(find.byType(TextField).at(1), 'thi thể.');
    await tester.tap(find.text('Lưu'));
    await waitUntil(
      tester,
      () => find.textContaining('thi thể.').evaluate().isNotEmpty,
    );

    expect(await tester.runAsync(() => db.getWordFixes()), [
      const WordFix('thi th ể', 'thi thể.'),
    ]);
  });

  testWidgets('Xoá cụm từ có xác nhận', (tester) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(
      () => db.setWordFixes([const WordFix('gi ết', 'giết')]),
    );
    await pumpScreen(tester, db);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();
    expect(find.text('"gi ết" sẽ không còn được tự thay nữa.'), findsOneWidget);
    await tester.tap(find.text('Xoá'));
    await waitUntil(
      tester,
      () => find.text('Chưa có cụm từ nào').evaluate().isNotEmpty,
    );

    expect(await tester.runAsync(() => db.getWordFixes()), isEmpty);
  });

  testWidgets('Dòng chỉ một truyện ghi tên truyện; thêm mới là mọi truyện', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    const story = 'https://x/truyen-ten';
    await tester.runAsync(
      () => db.upsertLibrary(
        storyUrl: story,
        title: 'Truyện Có Tên',
        lastChapterUrl: '$story/1',
      ),
    );
    await tester.runAsync(
      () => db.setWordFixes([
        const WordFix('chung', 'ok'),
        const WordFix('riêng', 'ổn', storyUrl: story),
        const WordFix(
          'mất tên',
          'x',
          storyUrl: 'https://x/khong-co-trong-thu-vien',
        ),
      ]),
    );
    await pumpScreen(tester, db);

    expect(find.textContaining('Mọi truyện'), findsOneWidget);
    expect(find.textContaining('Truyện Có Tên'), findsOneWidget);
    expect(find.textContaining('Chỉ một truyện'), findsOneWidget);

    await openEditor(tester, find.text('Thêm cụm từ'));
    expect(find.text('Chỉ truyện này'), findsNothing);
    expect(find.text('Áp dụng cho: Mọi truyện'), findsOneWidget);
    await tester.tap(find.text('Huỷ'));
    await waitUntil(tester, () => find.text('Lưu').evaluate().isEmpty);
  });

  testWidgets('Từ màn đọc: mặc định chỉ truyện này, không đè mục chung', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(
      () => db.setWordFixes([const WordFix('gi ết', 'giết')]),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showWordFixEditor(
                ctx,
                db,
                initialWrong: 'gi ết',
                storyChoice: 'https://x/truyen-a',
                storyLabel: 'Truyện A',
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await openEditor(tester, find.text('open'));
    expect(find.text('Chỉ truyện này'), findsOneWidget);
    expect(find.text('Truyện A'), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(1), 'GIẾT');
    await tester.tap(find.text('Lưu'));
    await waitUntil(tester, () => find.text('Lưu').evaluate().isEmpty);

    expect(await tester.runAsync(() => db.getWordFixes()), [
      const WordFix('gi ết', 'giết'),
      const WordFix('gi ết', 'GIẾT', storyUrl: 'https://x/truyen-a'),
    ]);

    await openEditor(tester, find.text('open'));
    await tester.tap(find.text('Mọi truyện'));
    await tester.enterText(find.byType(TextField).at(1), 'giết hết');
    await tester.tap(find.text('Lưu'));
    await waitUntil(tester, () => find.text('Lưu').evaluate().isEmpty);
    expect(await tester.runAsync(() => db.getWordFixes()), [
      const WordFix('gi ết', 'giết hết'),
      const WordFix('gi ết', 'GIẾT', storyUrl: 'https://x/truyen-a'),
    ]);
  });
}
