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
void main() {
  const channel = MethodChannel('story_reader/updater');
  var canInstall = false;
  var permissionScreenOpened = 0;

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
    permissionScreenOpened = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'canInstallApks':
          return canInstall;
        case 'openInstallPermissionSettings':
          permissionScreenOpened++;
          return null;
      }
      return null;
    });
  });

  Future<void> openDialog(WidgetTester tester, AppDb db) async {
    final update = UpdateInfo(
      version: '9.9.9',
      changelog: 'Ghi chú bản mới.',
      url: 'https://example.com/app.apk',
      directApk: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: TextButton(
                onPressed: () => AppUpdater.showUpdateDialog(
                  ctx,
                  db: db,
                  update: update,
                ),
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

  testWidgets('Cấp quyền xong quay lại app: tự chuyển sang bước tải', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_updater_dialog.db');
    await openDialog(tester, db);
    expect(find.text('Cấp quyền'), findsOneWidget);

    // Bấm Cấp quyền → native mở màn hình hệ thống.
    await tester.tap(find.text('Cấp quyền'));
    await tester.pump();
    expect(permissionScreenOpened, 1);

    // Người dùng bật quyền rồi quay lại app (lifecycle resumed).
    canInstall = true;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('Tải về & cài đặt'), findsOneWidget);
    expect(find.text('Cấp quyền'), findsNothing);
  });

  testWidgets('Đủ quyền sẵn: vào thẳng bước tải, không hỏi quyền', (tester) async {
    canInstall = true;
    final db = AppDb(fileName: 'test_updater_dialog.db');
    await openDialog(tester, db);

    expect(find.text('Tải về & cài đặt'), findsOneWidget);
    expect(find.text('Cấp quyền'), findsNothing);
    expect(find.textContaining('Ghi chú bản mới'), findsOneWidget);
  });
}
