import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thông báo hệ thống cho chương mới. Không xin quyền lúc mở app — chỉ xin
/// khi người dùng bật tính năng (hoặc lần đầu bấm nghe, do TTS cần quyền này
/// cho nút điều khiển trên màn khoá).
class AppNotifications {
  AppNotifications._();
  static final instance = AppNotifications._();

  static const channelId = 'new_chapters';
  static const _id = 1001;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    if (!Platform.isAndroid) return;
    try {
      await _plugin.initialize(
        settings: const InitializationSettings(
          // Icon chuông trắng trong res/drawable; mipmap launcher không dùng
          // làm small icon thông báo được (Android tìm theo drawable).
          android: AndroidInitializationSettings('ic_notification'),
        ),
      );
    } catch (e) {
      debugPrint('Không khởi tạo được thông báo: $e');
    }
  }

  /// true nếu đã có quyền (hoặc vừa được cấp). Lỗi nền trả false để nơi gọi
  /// hiện cảnh báo thay vì im lặng.
  Future<bool> ensurePermission() async {
    try {
      if (await Permission.notification.isGranted) return true;
      return (await Permission.notification.request()).isGranted;
    } catch (e) {
      debugPrint('Xin quyền thông báo lỗi: $e');
      return false;
    }
  }

  /// Hiện thông báo "có chương mới" gộp cả thư viện. Trả false khi không hiện
  /// được (máy thiếu quyền/không phải Android) để nơi gọi còn đường snackbar.
  Future<bool> showNewChapters({
    required int fresh,
    required List<String> titles,
  }) async {
    if (!Platform.isAndroid) return false;
    await init();
    try {
      final names = titles.where((t) => t.trim().isNotEmpty).toList();
      final head = names.take(3).join(', ');
      final body = names.length <= 3
          ? head
          : '$head và ${names.length - 3} truyện khác';
      await _plugin.show(
        id: _id,
        title: fresh == 1
            ? 'Truyện có chương mới'
            : '$fresh truyện có chương mới',
        body: body.isEmpty ? 'Mở app để đọc tiếp' : body,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            'Chương mới',
            channelDescription: 'Báo khi truyện trong thư viện có chương mới',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
          ),
        ),
      );
      return true;
    } catch (e) {
      debugPrint('Hiện thông báo lỗi: $e');
      return false;
    }
  }
}
