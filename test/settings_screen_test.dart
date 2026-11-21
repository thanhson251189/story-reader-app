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
    final path = p.join(await getDatabasesPath(), 'story_reader.db');
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
    final db = AppDb();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDbProvider.overrideWithValue(db)],
          child: const MaterialApp(home: SettingsScreen()),
        ),
      );
      // Chờ thật cho _load (version + setting) hoàn tất rồi mới bơm frame
      // setState — pumpAndSettle một mình thoát ngay vì chưa có frame nào.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
    });
    return db;
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
    expect(find.text('Quản lý nguồn truyện'), findsOneWidget);
    expect(find.text('Sao lưu dữ liệu'), findsOneWidget);
    expect(find.text('Phục hồi từ file sao lưu'), findsOneWidget);
  });

  testWidgets('Tắt/bật tự kiểm tra chương mới lưu vào DB', (tester) async {
    final db = await pumpSettings(tester);
    expect(
      await tester.runAsync(() => db.getSetting('autoCheckNew')) ?? '1',
      '1',
    );

    // Mặc định bật: gạt tắt thì DB ghi '0', gạt lại thì về '1'. Sau mỗi lần
    // gạt phải chờ thật cho setSetting ghi DB xong rồi mới bơm frame setState.
    Future<void> toggle() => tester.runAsync(() async {
      await tester.tap(find.byType(Switch));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
    });

    await toggle();
    expect(
      await tester.runAsync(() => db.getSetting('autoCheckNew')),
      '0',
    );

    await toggle();
    expect(
      await tester.runAsync(() => db.getSetting('autoCheckNew')),
      '1',
    );
  });
}
