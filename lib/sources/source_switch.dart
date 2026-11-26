import '../core/models.dart';
import '../fetcher/web_fetcher.dart';
import '../reader/toc_screen.dart';
import 'registry.dart';

/// Ghép chương đang đọc ở nguồn cũ sang mục lục nguồn mới. Không có tác
/// giả để so, nên thứ tự tin cậy là: cùng số chương → cùng tên chương →
/// cùng vị trí trong mục lục → chương đầu. Trả null khi mục lục mới rỗng.
class SourceSwitch {
  /// Nguồn có thể tìm lại truyện: có ô tìm kiếm, khác nguồn đang đọc, và bị
  /// loại khi đang bật ẩn 18+ — cùng quy tắc với Tìm kiếm/Khám phá/Thư viện.
  /// Hàm thuần để test được mà không phải dựng màn.
  static List<SourceAdapter> availableTargets({
    required List<SourceAdapter> adapters,
    required String? currentDomain,
    required bool hideAdult,
    required Set<String> adultDomains,
  }) {
    return adapters.where((a) {
      if (a.searchUrl == null || a.domain == currentDomain) return false;
      return !(hideAdult &&
          SourceRegistry.isAdultHost(a.domain, adultDomains));
    }).toList()..sort((a, b) => a.domain.compareTo(b.domain));
  }

  static ChapterRef? mapChapter({
    required List<ChapterRef> oldToc,
    required String currentChapterUrl,
    required String currentChapterTitle,
    required List<ChapterRef> newToc,
  }) {
    if (newToc.isEmpty) return null;

    final number = WebFetcher.trailingNumber(currentChapterUrl);
    if (number != null) {
      for (final c in newToc) {
        if (WebFetcher.trailingNumber(c.url) == number) return c;
      }
    }

    final title = TocScreen.fold(currentChapterTitle.trim());
    if (title.isNotEmpty) {
      for (final c in newToc) {
        if (TocScreen.fold(c.title.trim()) == title) return c;
      }
    }

    final want = normalizeChapterUrl(currentChapterUrl);
    final oldIndex = oldToc.indexWhere(
      (c) => normalizeChapterUrl(c.url) == want,
    );
    if (oldIndex >= 0 && oldIndex < newToc.length) return newToc[oldIndex];

    return newToc.first;
  }
}
