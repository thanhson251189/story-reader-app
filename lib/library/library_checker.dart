import 'package:flutter/foundation.dart';

import '../adapters/adapter_repository.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';

class LibraryCheckResult {
  final int fresh;
  final List<String> warns;
  final bool cancelled;

  /// false khi một lượt kiểm tra khác đang chạy — người gọi không được
  /// ghi đè mốc thời gian của lượt đó.
  final bool ran;
  const LibraryCheckResult(
    this.fresh,
    this.warns, {
    this.cancelled = false,
    this.ran = true,
  });
}

/// Kiểm tra chương mới cho các truyện web trong thư viện. Dùng chung cho nút
/// bấm tay trên màn Thư viện và lần chạy ngầm lúc mở app; chỉ cho một luồng
/// chạy tại một thời điểm để không đập trùng vào nguồn truyện bị chặn theo
/// số lượt tải.
class LibraryChecker {
  static bool _running = false;
  static bool get running => _running;
  static bool _cancel = false;

  /// Nghỉ giữa các truyện khi kiểm tra, cùng lý do bộ tải chương nghỉ 5s:
  /// tải liền một mạch dễ bị trang web chặn.
  static const storyGap = Duration(seconds: 5);

  /// Không tự kiểm tra lại trong khoảng này. Quét cả thư viện mỗi lần mở app
  /// mất vài phút và dễ bị chặn; nút trên thư viện vẫn kiểm tra ngay.
  static const checkGap = Duration(hours: 6);
  static const lastCheckKey = 'libraryCheckAt';

  static bool isDue(int? lastMs, DateTime now, {Duration gap = checkGap}) {
    if (lastMs == null || lastMs <= 0) return true;
    return !now.isBefore(DateTime.fromMillisecondsSinceEpoch(lastMs).add(gap));
  }

  /// Tăng lên sau mỗi lần chạy xong để màn Thư viện đang mở nạp lại dữ liệu.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Dòng tiến độ lúc đang chạy; null khi không chạy. Màn Thư viện nghe cái
  /// này để hiện nút Dừng, kể cả lượt kiểm tra do mở app khởi động.
  static final ValueNotifier<String?> progress = ValueNotifier<String?>(null);

  static void cancel() {
    _cancel = true;
  }

  static Future<bool> _pause(Duration gap) async {
    const step = Duration(milliseconds: 200);
    var left = gap;
    while (left > Duration.zero) {
      if (_cancel) return false;
      final slice = left < step ? left : step;
      await Future<void>.delayed(slice);
      left -= slice;
    }
    return !_cancel;
  }

  static Future<LibraryCheckResult> check({
    required AppDb db,
    required WebFetcher fetcher,
    required AdapterRepository repo,
    List<Map<String, dynamic>>? items,
    void Function(String progress)? onProgress,
    Duration gap = storyGap,
  }) async {
    if (_running) {
      return const LibraryCheckResult(0, [], ran: false);
    }
    _running = true;
    _cancel = false;
    progress.value = 'Đang bắt đầu';
    try {
      final lib = items ?? await db.getLibrary();
      final targets = lib
          .where((i) => !(i['story_url'] as String? ?? '').startsWith('book:'))
          .toList();
      var fresh = 0;
      final warns = <String>[];
      for (var i = 0; i < targets.length; i++) {
        if (_cancel) {
          revision.value++;
          return LibraryCheckResult(fresh, warns, cancelled: true);
        }
        if (i > 0 && gap > Duration.zero) {
          final paused = await _pause(gap);
          if (!paused) {
            revision.value++;
            return LibraryCheckResult(fresh, warns, cancelled: true);
          }
        }
        final item = targets[i];
        final storyUrl = item['story_url'] as String;
        final title = item['title'] as String? ?? storyUrl;
        final line = '${i + 1}/${targets.length}: $title';
        progress.value = line;
        onProgress?.call(line);
        final adapter = repo.forUrl(storyUrl);
        if (adapter == null) {
          warns.add('$title: chưa cài nguồn — mở màn "Nguồn truyện" để thêm');
          continue;
        }
        try {
          final info = await fetcher.fetchStory(storyUrl, adapter);
          if (_cancel) {
            revision.value++;
            return LibraryCheckResult(fresh, warns, cancelled: true);
          }
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
          // "Có chương mới" = chương cuối trên web khác lần kiểm tra trước,
          // không phải khác chương đang đọc. Đang đọc dở không được tính là
          // vừa có chương mới mỗi lần mở app. Lần đầu chưa có mốc thì chỉ ghi
          // mốc, không báo.
          final prevLatest = item['latest_chapter_url'] as String?;
          final isNew =
              prevLatest != null &&
              prevLatest.isNotEmpty &&
              !sameChapterUrl(last.url, prevLatest);
          await db.setLatestChapter(storyUrl, last.url, last.title);
          if (isNew) fresh++;
        } catch (e) {
          warns.add('$title: ${friendlyError(e)}');
        }
      }
      revision.value++;
      return LibraryCheckResult(fresh, warns);
    } finally {
      _running = false;
      _cancel = false;
      progress.value = null;
    }
  }
}
