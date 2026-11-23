import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/update/app_updater.dart';

/// Test hộp thoại cập nhật: bước CẤP QUYỀN phải hiện TRƯỚC khi tải (thiếu
/// quyền mà để tải xong 60MB mới báo lỗi là phí mạng + thời gian người dùng
/// — bug user báo "tải xong không có gì xảy ra"). Channel giả: canInstallApks
/// trả theo kịch bản, openInstallPermissionSettings đếm số lần mở.
///
/// Lưu ý: KHÔNG test luồng tải thật ở đây — binding fake-async chặn HTTP
/// thành spinner treo mãi (bài học từ app_updater_test); test luồng tải dùng
/// URL hỏng fail đồng bộ để chứng minh luồng tải TỰ chạy sau khi cấp quyền.
void main() {
  const channel = MethodChannel('story_reader/updater');
  var canInstall = false;
  var settingsOpened = false;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), 'test_updater_dialog.db');
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  setUp(() {
    canInstall = false;
    settingsOpened = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'canInstallApks':
              return canInstall;
            case 'openInstallPermissionSettings':
              return settingsOpened;
          }
          return null;
        });
    // Luồng tải ghi file vào thư mục tạm: không mock thì trong fake-async
    // zone invokeMethod path_provider không có hồi đáp, spinner treo mãi.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
  });

  Future<void> openDialog(
    WidgetTester tester,
    AppDb db, {
    bool directApk = true,
    String? url,
  }) async {
    final update = UpdateInfo(
      version: '9.9.9',
      changelog: 'Ghi chú bản mới.',
      url: url ?? 'https://example.com/app.apk',
      directApk: directApk,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () =>
                    AppUpdater.showUpdateDialog(ctx, db: db, update: update),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('Thiếu quyền cài: hiện bước Cấp quyền TRƯỚC khi tải', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_updater_dialog.db');
    await openDialog(tester, db);

    expect(
      find.text('Cần quyền "Cài ứng dụng không rõ nguồn" để cài bản cập nhật.'),
      findsOneWidget,
    );
    expect(find.text('Cấp quyền'), findsOneWidget);
    // Chưa được phép tải: không hiện nút tải về.
    expect(find.text('Tải về & cài đặt'), findsNothing);
  });

  testWidgets('Đủ quyền sẵn: vào thẳng bước tải, không hỏi quyền', (
    tester,
  ) async {
    canInstall = true;
    final db = AppDb(fileName: 'test_updater_dialog.db');
    await openDialog(tester, db);

    expect(find.text('Tải về & cài đặt'), findsOneWidget);
    expect(find.text('Cấp quyền'), findsNothing);
    expect(find.textContaining('Ghi chú bản mới'), findsOneWidget);
  });

  testWidgets('Release không kèm APK + thiếu quyền: không bắt cấp quyền', (
    tester,
  ) async {
    // Mở trang tải qua trình duyệt KHÔNG cần quyền cài APK: bắt cấp quyền là
    // chặn oan cả nút "Mở trang tải" của đường fallback.
    final db = AppDb(fileName: 'test_updater_dialog.db');
    await openDialog(tester, db, directApk: false);

    expect(find.text('Cấp quyền'), findsNothing);
    expect(find.text('Mở trang tải'), findsOneWidget);
    expect(find.textContaining('Ghi chú bản mới'), findsOneWidget);
  });

  testWidgets('Không mở được màn cấp quyền thì có câu báo, không im lặng', (
    tester,
  ) async {
    settingsOpened = false;
    final db = AppDb(fileName: 'test_updater_dialog.db');
    await openDialog(tester, db);

    await tester.tap(find.text('Cấp quyền'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('Không mở được màn hình cấp quyền'),
      findsOneWidget,
    );
    // Vẫn đứng ở bước cấp quyền để bấm lại, không nhảy sang tải.
    expect(find.text('Cấp quyền'), findsOneWidget);
    expect(find.text('Tải về & cài đặt'), findsNothing);
  });
}
