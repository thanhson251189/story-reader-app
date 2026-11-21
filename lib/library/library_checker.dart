import 'package:flutter/foundation.dart';

import '../adapters/adapter_repository.dart';
import '../core/errors.dart';
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

  /// Tăng lên sau mỗi lần chạy xong để màn Thư viện đang mở nạp lại dữ liệu.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static Future<LibraryCheckResult> check({
    required AppDb db,
    required WebFetcher fetcher,
    required AdapterRepository repo,
    List<Map<String, dynamic>>? items,
    void Function(String progress)? onProgress,
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
          final last = info.chapters.last;
          // Không truyền lastChapterUrl: chỉ làm mới mục lục và ghi chương
          // mới nhất, không đụng dòng "đang đọc" của thư viện.
          await db.saveStoryInfo(storyUrl, info);
          await db.setLatestChapter(storyUrl, last.url, last.title);
          if (last.url != (item['last_chapter_url'] as String? ?? '')) fresh++;
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
