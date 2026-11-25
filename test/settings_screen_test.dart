import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/settings/settings_screen.dart';

/// Test màn Cài đặt: DB thật qua FFI, phiên bản giả qua channel của
/// package_info_plus. DB thật trả kết quả qua event loop thật nên mọi chờ
/// liên quan DB phải bọc [tester.runAsync] — không thì treo trong vùng
/// fake-async của testWidgets (bài học từ lần chạy đầu).
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), 'test_settings_screen.db');
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  Future<AppDb> pumpSettings(WidgetTester tester) async {
    const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return {
            'appName': 'Story Reader',
            'packageName': 'dev.storyreader.story_reader',
            'version': '9.9.9',
            'buildNumber': '99',
            'buildSignature': '',
            'installerStore': null,
          };
        });
    final db = AppDb(fileName: 'test_settings_screen.db');
    // Chờ thật cho _load (version + setting) hoàn tất rồi mới bơm frame
    // setState — pumpAndSettle một mình thoát ngay vì chưa có frame nào;
    // POLL theo điều kiện thay vì chờ cố định (thời gian mở DB lạnh thay
    // đổi, chờ cứng thỉnh thoảng không đủ).
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() async {
        if (i == 0) {
          await tester.pumpWidget(
            ProviderScope(
              overrides: [appDbProvider.overrideWithValue(db)],
              child: const MaterialApp(home: SettingsScreen()),
            ),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();
      });
      // Placeholder '…' biến mất = version + setting nạp xong.
      if (find.text('…').evaluate().isEmpty) return db;
    }
    fail('Màn Cài đặt không nạp xong');
  }

  testWidgets('Màn Cài đặt hiện phiên bản app và các mục cài đặt', (
    tester,
  ) async {
    await pumpSettings(tester);

    expect(find.text('Phiên bản'), findsOneWidget);
    expect(find.textContaining('v9.9.9'), findsOneWidget);
    expect(find.textContaining('bản dựng 99'), findsOneWidget);
    expect(find.text('Kiểm tra cập nhật'), findsOneWidget);
    expect(find.text('Tự kiểm tra chương mới khi mở app'), findsOneWidget);
    expect(find.text('Ẩn nguồn 18+'), findsOneWidget);
    expect(find.text('Báo chương mới bằng thông báo'), findsOneWidget);
    expect(find.text('Quản lý nguồn truyện'), findsOneWidget);
    // Thêm công tắc mới đẩy mục Dữ liệu xuống dưới màn: cuộn tới rồi mới thấy.
    await tester.scrollUntilVisible(
      find.text('Sao lưu dữ liệu'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Sao lưu dữ liệu'), findsOneWidget);
    expect(find.text('Phục hồi từ file sao lưu'), findsOneWidget);
  });

  testWidgets('Tắt/bật tự kiểm tra chương mới lưu vào DB', (tester) async {
    final db = await pumpSettings(tester);
    expect(
      await tester.runAsync(() => db.getSetting('autoCheckNew')) ?? '1',
      '1',
    );

    // Mặc định bật: gạt tắt thì DB ghi '0', gạt lại thì về '1'. Gạt ĐÚNG MỘT
    // LẦN rồi poll chờ setSetting ghi DB xong + frame setState đổi công tắc —
    // gạt lại trong lúc write chưa xong là gạt ngược về giá trị cũ.
    final tile = find.byKey(const ValueKey('auto-check-new'));
    Future<void> toggleTo(bool value) async {
      await tester.runAsync(() => tester.tap(tile));
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pumpAndSettle();
        });
        final sw = tester.widget<Switch>(
          find.descendant(of: tile, matching: find.byType(Switch)),
        );
        if (sw.value == value) {
          return;
        }
      }
      fail('Công tắc không đổi sang $value');
    }

    await toggleTo(false);
    expect(await tester.runAsync(() => db.getSetting('autoCheckNew')), '0');

    await toggleTo(true);
    expect(await tester.runAsync(() => db.getSetting('autoCheckNew')), '1');
  });
}
