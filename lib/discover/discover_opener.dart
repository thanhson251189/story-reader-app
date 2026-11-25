import '../adapters/adapter_repository.dart';
import '../core/errors.dart';
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
/// dạng link (mỗi trang một kiểu): thử bóc nội dung chương trước — trang
/// truyện thường không có khối nội dung chương; không ra thì thử mục lục.
class DiscoverOpener {
  final WebFetcher fetcher;
  final AdapterRepository repo;

  DiscoverOpener({required this.fetcher, required this.repo});

  Future<DiscoverPage> open(String url) async {
    final adapter = repo.forUrl(url);
    if (adapter == null) {
      return DiscoverPage.failed(
        url,
        'Trang này thuộc nguồn chưa cài trong app. Vào Nguồn truyện để thêm.',
      );
    }
    // Trang chương: có nội dung là tín hiệu chắc nhất. Lỗi ở bước này không
    // chặn bước sau — trang truyện cũng có thể trả lỗi bóc nội dung.
    try {
      final c = await fetcher.fetchChapter(url, adapter);
      if (c.paragraphs.isNotEmpty) return DiscoverPage.chapter(url, c);
    } catch (_) {}
    try {
      final info = await fetcher.fetchStory(url, adapter);
      if (info.chapters.isNotEmpty) return DiscoverPage.story(url, info);
    } catch (e) {
      return DiscoverPage.failed(url, friendlyError(e));
    }
    return DiscoverPage.failed(
      url,
      'Không nhận ra trang truyện hay trang chương. Mở trang truyện hoặc '
      'trang chương trên web rồi bấm lại.',
    );
  }
}
