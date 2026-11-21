class TocApi {
  final String novelUrl;
  final String listUrl;
  final String chapterUrl;

  TocApi({
    required this.novelUrl,
    required this.listUrl,
    required this.chapterUrl,
  });

  factory TocApi.fromJson(Map<String, dynamic> j) => TocApi(
    novelUrl: j['novelUrl'] as String,
    listUrl: j['listUrl'] as String,
    chapterUrl: j['chapterUrl'] as String,
  );
}

class SourceAdapter {
  final String domain;
  final int version;
  final Map<String, String> selectors;
  final List<String> removeSelectors;
  final List<Map<String, String>> textCleanup;
  final String? searchUrl;
  final TocApi? tocApi;
  // Mục lục phân trang HTML (site không có JSON API): template chứa {slug} và {page}.
  final String? tocPageUrl;

  SourceAdapter({
    required this.domain,
    required this.version,
    required this.selectors,
    required this.removeSelectors,
    required this.textCleanup,
    this.searchUrl,
    this.tocApi,
    this.tocPageUrl,
  });

  factory SourceAdapter.fromJson(Map<String, dynamic> j) => SourceAdapter(
    domain: j['domain'] as String,
    version: (j['version'] as num?)?.toInt() ?? 1,
    selectors: Map<String, String>.from(j['selectors'] as Map? ?? {}),
    removeSelectors: List<String>.from(j['removeSelectors'] as List? ?? []),
    textCleanup: (j['textCleanup'] as List? ?? [])
        .map((e) => Map<String, String>.from(e as Map))
        .toList(),
    searchUrl: j['searchUrl'] as String?,
    tocApi: j['tocApi'] == null
        ? null
        : TocApi.fromJson(Map<String, dynamic>.from(j['tocApi'] as Map)),
    tocPageUrl: j['tocPageUrl'] as String?,
  );

  SourceAdapter withSearch(String url, Map<String, String> extraSelectors) =>
      SourceAdapter(
        domain: domain,
        version: version,
        selectors: {...selectors, ...extraSelectors},
        removeSelectors: removeSelectors,
        textCleanup: textCleanup,
        searchUrl: url,
        tocApi: tocApi,
        tocPageUrl: tocPageUrl,
      );

  bool matches(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    return host == domain || host.endsWith('.$domain');
  }

  String clean(String text) {
    var t = text;
    for (final rule in textCleanup) {
      final p = rule['pattern'];
      if (p == null || p.isEmpty) continue;
      t = t.replaceAll(RegExp(p), rule['replacement'] ?? '');
    }
    return t.trim();
  }
}

class ChapterContent {
  final String url;
  final String title;
  final List<String> paragraphs;
  final String? nextUrl;
  final String? prevUrl;

  ChapterContent({
    required this.url,
    required this.title,
    required this.paragraphs,
    this.nextUrl,
    this.prevUrl,
  });

  factory ChapterContent.fromJson(Map<String, dynamic> j) => ChapterContent(
    url: j['url'] as String? ?? '',
    title: j['title'] as String? ?? '',
    paragraphs: List<String>.from(j['paragraphs'] as List? ?? []),
    nextUrl: j['nextUrl'] as String?,
    prevUrl: j['prevUrl'] as String?,
  );
}

class ChapterRef {
  final String title;
  final String url;
  ChapterRef({required this.title, required this.url});

  factory ChapterRef.fromJson(Map<String, dynamic> j) => ChapterRef(
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
  );
}

class NovelInfo {
  final String title;
  final String? coverUrl;
  final List<ChapterRef> chapters;

  NovelInfo({required this.title, this.coverUrl, required this.chapters});

  factory NovelInfo.fromJson(Map<String, dynamic> j) => NovelInfo(
    title: j['title'] as String? ?? '',
    coverUrl: j['coverUrl'] as String?,
    chapters: (j['chapters'] as List? ?? [])
        .map((e) => ChapterRef.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
  );
}

class SearchResult {
  final String title;
  final String url;
  final String? coverUrl;
  SearchResult({required this.title, required this.url, this.coverUrl});

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
    title: j['title'] as String? ?? '',
    url: j['url'] as String? ?? '',
    coverUrl: j['coverUrl'] as String?,
  );
}

class ChallengeException implements Exception {
  @override
  String toString() => 'Trang đang chặn bot, cần mở WebView để vượt kiểm tra';
}

/// Cấu trúc địa chỉ chương sách nhập từ file: `book:<mã sách>:<số chương>`.
/// Một nơi duy nhất cắt chuỗi để mọi màn hình hiểu địa chỉ sách giống nhau.
class BookUrl {
  /// Phần định danh truyện `book:<mã>` (bỏ số chương).
  static String storyOf(String url) {
    final parts = url.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : url;
  }

  /// Số thứ tự chương (bắt đầu từ 0) hoặc null nếu địa chỉ không có số.
  static int? chapterOf(String url) {
    if (!url.startsWith('book:')) return null;
    final parts = url.split(':');
    return parts.length >= 3 ? int.tryParse(parts[2]) : null;
  }
}

/// Suy ra URL truyện từ URL chương: với sách trong máy là phần định danh
/// `book:<mã>`; với trang web là URL chương bỏ đoạn cuối. Trang đơn như
/// wikisource không suy được kiểu này (nơi mở đã biết thì truyền thẳng).
String storyUrlFromChapter(String url) {
  if (url.startsWith('book:')) return BookUrl.storyOf(url);
  final uri = Uri.parse(url).removeFragment();
  // Bỏ segment rỗng do dấu '/' cuối để không cắt nhầm vào tên chương.
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isNotEmpty) segs.removeLast();
  final slash = url.endsWith('/') ? '/' : '';
  return uri.replace(path: '/${segs.join('/')}$slash').toString();
}
