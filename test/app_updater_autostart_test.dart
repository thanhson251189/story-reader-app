import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/update/app_updater.dart';

/// Test riêng cho luồng "cấp quyền xong TỰ tải về và cài": chuỗi callback
/// chạy qua channel + luồng tải cần real async (runAsync) và để lại state
/// rò sang testWidgets kế trong CÙNG file (Timer pending invariant) — tách
/// file để chạy isolate riêng, không dây chuyền (bài học file test quyền).
void main() {
  const channel = MethodChannel('story_reader/updater');
  var canInstall = false;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    canInstall = false;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'canInstallApks':
          return canInstall;
        case 'openInstallPermissionSettings':
          return null;
      }
      return null;
    });
    // Luồng tải ghi file vào thư mục tạm: không mock thì trong fake-async
    // zone invokeMethod path_provider không có hồi đáp, spinner treo mãi.
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
  });

  Future<void> openDialog(WidgetTester tester, AppDb db, String url) async {
    final update = UpdateInfo(
      version: '9.9.9',
      changelog: 'Ghi chú bản mới.',
      url: url,
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

  testWidgets('Cấp quyền xong quay lại app: TỰ bước vào luồng tải, không bắt bấm nút thêm lần nữa', (
    tester,
  ) async {
    final db = AppDb(fileName: 'test_updater_autostart.db');
    // URL hỏng để luồng tải tự chạy rồi fail NGAY (FormatException đồng bộ):
    // tránh HTTP thật bị fake-async zone chặn thành spinner treo mãi — điều
    // cần chứng minh là TỰ TẢI ĐÃ ĐƯỢC GỌI sau khi cấp quyền xong.
    await openDialog(tester, db, 'http://[bad/app.apk');
    expect(find.text('Cấp quyền'), findsOneWidget);

    // Bấm Cấp quyền → native mở màn hình hệ thống.
    await tester.tap(find.text('Cấp quyền'));
    await tester.pump();

    // Người dùng bật quyền rồi quay lại app (lifecycle resumed) — bước Cấp
    // quyền đã hứa "tự tải về và cài tiếp": phải tự chạy luồng tải, không
    // hiện lại nút "Tải về & cài đặt" bắt bấm thêm. Chuỗi callback qua
    // channel cần real async (fake-async zone không flush reply) → runAsync.
    canInstall = true;
    await tester.runAsync(() async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pumpAndSettle();

    expect(find.text('Cấp quyền'), findsNothing);
    expect(
      find.textContaining('Tải về lỗi'),
      findsOneWidget,
      reason: 'phải TỰ bắt đầu tải sau khi cấp quyền xong (lỗi này là của '
          'URL hỏng cố ý trong test, không phải của luồng quyền)',
    );
    expect(find.text('Tải về & cài đặt'), findsNothing);

    // Drain reply còn treo (DB ghi trong dispose...) trước khi fake zone
    // kiểm tra invariant "không Timer pending".
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  });
}
