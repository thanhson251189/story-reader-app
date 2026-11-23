import 'package:flutter/foundation.dart';

import '../adapters/adapter_repository.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';

class LibraryCheckResult {
  final int fresh;
  final List<String> warns;
  const LibraryCheckResult(this.fresh, this.warns);
}

/// Kiểm tra chương mới cho các truyện web trong thư viện. Dùng chung cho nút
/// bấm tay trên màn Thư viện và lần chạy ngầm lúc mở app; chỉ cho một luồng
/// chạy tại một thời điểm để không đập trùng vào nguồn truyện bị chặn theo
/// số lượt tải.
class LibraryChecker {
  static bool _running = false;
  static bool get running => _running;

  /// Nghỉ giữa các truyện khi kiểm tra ngầm, cùng lý do bộ tải chương nghỉ 5s:
  /// tải liền một mạch dễ bị trang web chặn.
  static const storyGap = Duration(seconds: 5);

  /// Tăng lên sau mỗi lần chạy xong để màn Thư viện đang mở nạp lại dữ liệu.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<LibraryCheckResult> check({
    required AppDb db,
    required WebFetcher fetcher,
    required AdapterRepository repo,
    List<Map<String, dynamic>>? items,
    void Function(String progress)? onProgress,
    Duration gap = storyGap,
  }) async {
    if (_running) return const LibraryCheckResult(0, []);
    _running = true;
    try {
      final lib = items ?? await db.getLibrary();
      final targets = lib
          .where((i) => !(i['story_url'] as String? ?? '').startsWith('book:'))
          .toList();
      var fresh = 0;
      final warns = <String>[];
      for (var i = 0; i < targets.length; i++) {
        if (i > 0 && gap > Duration.zero) {
          await Future<void>.delayed(gap);
        }
        final item = targets[i];
        final storyUrl = item['story_url'] as String;
        final title = item['title'] as String? ?? storyUrl;
        onProgress?.call('${i + 1}/${targets.length}: $title');
        final adapter = repo.forUrl(storyUrl);
        if (adapter == null) {
          warns.add('$title: chưa cài nguồn — mở màn "Nguồn truyện" để thêm');
          continue;
        }
        try {
          final info = await fetcher.fetchStory(storyUrl, adapter);
          if (info.chapters.isEmpty) {
            warns.add('$title: không lấy được mục lục');
            continue;
          }
          // Bản thiếu hoặc ngắn hơn bản đang lưu: không ghi đè, không cập nhật
          // "chương mới nhất" theo danh sách cụt (sẽ báo oan hoặc mất chương).
          final saved = await db.saveTocUnlessShorter(storyUrl, info);
          if (!saved) {
            warns.add('$title: mục lục tải chưa đủ, giữ danh sách chương cũ');
            continue;
          }
          final last = info.chapters.last;
          await db.setLatestChapter(storyUrl, last.url, last.title);
          if (!sameChapterUrl(last.url, item['last_chapter_url'] as String?)) {
            fresh++;
          }
        } catch (e) {
          warns.add('$title: ${friendlyError(e)}');
        }
      }
      revision.value++;
      return LibraryCheckResult(fresh, warns);
    } finally {
      _running = false;
    }
  }
}
