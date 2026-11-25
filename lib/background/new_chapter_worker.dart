import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import '../adapters/adapter_repository.dart';
import '../core/app_notifications.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';
import '../library/library_checker.dart';
import '../sources/registry.dart';

const _taskName = 'story_reader_new_chapters';

/// Entry point chạy trong isolate nền của WorkManager. Chỉ kiểm nguồn có API
/// JSON: WebView không đáng tin khi app đóng, còn HTTP thuần thì chạy được.
/// Không ghi mốc `libraryCheckAt` để lần mở app vẫn kiểm các nguồn WebView.
@pragma('vm:entry-point')
void newChapterCallbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    try {
      final db = AppDb();
      if ((await db.getSetting('notifyNewChapters') ?? '0') != '1') {
        return true;
      }
      final repo = AdapterRepository([]);
      await SourceRegistry.restoreInstalled(db, repo);
      final res = await LibraryChecker.check(
        db: db,
        fetcher: WebFetcher(),
        repo: repo,
        apiOnly: true,
      );
      if (res.fresh > 0) {
        await AppNotifications.instance.showNewChapters(
          fresh: res.fresh,
          titles: res.freshTitles,
        );
      }
      return true;
    } catch (e) {
      debugPrint('Kiểm chương mới nền lỗi: $e');
      return false;
    }
  });
}

/// Bật/tắt lượt kiểm chương mới định kỳ (6 giờ) của WorkManager. Chỉ có
/// tác dụng với nguồn API; nguồn WebView vẫn kiểm khi mở app như cũ.
class NewChapterScheduler {
  static bool _inited = false;

  static Future<void> _ensureInit() async {
    if (_inited) return;
    await Workmanager().initialize(newChapterCallbackDispatcher);
    _inited = true;
  }

  static Future<void> enable() async {
    await _ensureInit();
    await Workmanager().registerPeriodicTask(
      _taskName,
      _taskName,
      frequency: const Duration(hours: 6),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  static Future<void> disable() => Workmanager().cancelByUniqueName(_taskName);

  /// Lúc mở app: đăng ký lại nếu người dùng đã bật (WorkManager giữ task cũ,
  /// gọi lại không nhân đôi). Lỗi nền bỏ qua, chỉ log.
  static Future<void> sync(AppDb db) async {
    try {
      if ((await db.getSetting('notifyNewChapters') ?? '0') != '1') return;
      await enable();
    } catch (e) {
      debugPrint('Đăng ký kiểm chương mới nền lỗi: $e');
    }
  }
}
