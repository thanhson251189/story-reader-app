import '../adapters/adapter_repository.dart';
import '../core/models.dart';
import '../fetcher/web_fetcher.dart';

/// Kết quả nhận diện trang web đang xem: trang truyện (có mục lục), trang
/// chương (có nội dung), hoặc không nhận ra.
class DiscoverPage {
  /// Trang đang xem lúc bấm "Mở bằng app".
  final String url;
  final NovelInfo? story;
  final ChapterContent? chapter;
  final String? error;

  const DiscoverPage.story(this.url, NovelInfo this.story)
    : chapter = null,
      error = null;
  const DiscoverPage.chapter(this.url, ChapterContent this.chapter)
    : story = null,
      error = null;
  const DiscoverPage.failed(this.url, this.error)
    : story = null,
      chapter = null;
}

/// Nhận diện trang web đang mở bằng adapter của nguồn. Không đoán theo hình
/// dạng link (mỗi trang một kiểu).
///
/// Dò chương và mục lục chạy SONG SONG: trang chương thì bóc chương xong
/// trước, trang truyện thì không phải chờ hết vòng thử nội dung chương (trước
/// đây mất hơn 10 giây, nhìn như app treo). Kết quả chương được ưu tiên vì
/// trang chương cũng có link chương ở sidebar, không thể tin kết quả mục lục.
class DiscoverOpener {
  final WebFetcher fetcher;
  final AdapterRepository repo;

  /// Số lần đọc lại DOM khi dò. Trang của các nguồn hiện tại là SSR nên 3 lần
  /// là đủ; chờ lâu hơn chỉ làm người dùng tưởng treo.
  static const _probeTries = 3;

  DiscoverOpener({required this.fetcher, required this.repo});

  Future<DiscoverPage> open(String url) async {
    final adapter = repo.forUrl(url);
    if (adapter == null) {
      return DiscoverPage.failed(
        url,
        'Trang này thuộc nguồn chưa cài trong app. Vào Nguồn truyện để thêm.',
      );
    }
    Future<ChapterContent?> probeChapter() async {
      try {
        final c = await fetcher.fetchChapter(
          url,
          adapter,
          maxTries: _probeTries,
        );
        return c.paragraphs.isEmpty ? null : c;
      } catch (_) {
        return null;
      }
    }

    Future<NovelInfo?> probeStory() async {
      try {
        final info = await fetcher.fetchStory(
          url,
          adapter,
          maxTries: _probeTries,
        );
        return info.chapters.isEmpty ? null : info;
      } catch (_) {
        return null;
      }
    }

    final chapterFuture = probeChapter();
    final storyFuture = probeStory();
    final chapter = await chapterFuture;
    if (chapter != null) {
      // Mục lục vẫn đang dò dở ở nền; nó tự dọn, không chặn màn đọc.
      return DiscoverPage.chapter(url, chapter);
    }
    final story = await storyFuture;
    if (story != null) return DiscoverPage.story(url, story);
    return DiscoverPage.failed(
      url,
      'Không nhận ra trang truyện hay trang chương, hoặc trang đang chặn app. '
      'Mở lại đúng trang truyện/chương trong trình duyệt rồi dán link.',
    );
  }
}
