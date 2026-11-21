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

  testWidgets('Thêm cụm từ: hiện danh sách và lưu DB', (tester) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await pumpScreen(tester, db);
    expect(find.text('Chưa có cụm từ nào'), findsOneWidget);

    await tester.tap(find.text('Thêm cụm từ'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'gi ết');
    await tester.enterText(find.byType(TextField).at(1), 'giết');
    await tester.tap(find.text('Lưu'));
    await waitUntil(
      tester,
      () => find.text('Chưa có cụm từ nào').evaluate().isEmpty,
    );

    expect(find.text('gi ết'), findsOneWidget);
    expect(find.textContaining('→'), findsOneWidget);
    expect(
      await tester.runAsync(() => db.getWordFixes()),
      [('gi ết', 'giết')],
    );
  });

  testWidgets('Cụm từ trống hoặc trùng thì báo lỗi ngay trong hộp thoại', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(() => db.setWordFixes([('gi ết', 'giết')]));
    await pumpScreen(tester, db);

    await tester.tap(find.text('Thêm cụm từ'));
    await tester.pumpAndSettle();
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
    expect(
      await tester.runAsync(() => db.getWordFixes()),
      [('gi ết', 'giết')],
    );
  });

  testWidgets('Bấm dòng mở hộp thoại sửa, điền sẵn giá trị cũ', (tester) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(() => db.setWordFixes([('thi th ể', 'thi thể')]));
    await pumpScreen(tester, db);

    await tester.tap(find.text('thi th ể'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), 'thi thể.');
    await tester.tap(find.text('Lưu'));
    await waitUntil(
      tester,
      () => find.textContaining('thi thể.').evaluate().isNotEmpty,
    );

    expect(
      await tester.runAsync(() => db.getWordFixes()),
      [('thi th ể', 'thi thể.')],
    );
  });

  testWidgets('Xoá cụm từ có xác nhận', (tester) async {
    final db = AppDb(fileName: 'test_word_fix_screen.db');
    await tester.runAsync(() => db.setWordFixes([('gi ết', 'giết')]));
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
}
