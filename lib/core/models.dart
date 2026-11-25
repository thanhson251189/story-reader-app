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

/// API JSON của nền tảng CMS dùng chung (khotruyen.site và các site cùng mã):
/// một request trả nguyên truyện kèm mảng `chapters`; request chương cùng dạng
/// nhưng chỉ chương đang đọc có `bodyText`. Template dùng {slug}, {chapter},
/// {query}. Link trang web tách riêng để người đọc vẫn mở/chia sẻ được.
class SourceApi {
  final String? searchUrl;
  final String? storyUrl;
  final String? chapterUrl;
  final String? storyPageUrl;
  final String? chapterPageUrl;

  SourceApi({
    this.searchUrl,
    this.storyUrl,
    this.chapterUrl,
    this.storyPageUrl,
    this.chapterPageUrl,
  });

  factory SourceApi.fromJson(Map<String, dynamic> j) => SourceApi(
    searchUrl: j['searchUrl'] as String?,
    storyUrl: j['storyUrl'] as String?,
    chapterUrl: j['chapterUrl'] as String?,
    storyPageUrl: j['storyPageUrl'] as String?,
    chapterPageUrl: j['chapterPageUrl'] as String?,
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
  // API JSON kiểu CMS: tìm kiếm, mục lục, nội dung chương không cần WebView.
  final SourceApi? api;
  // Trang đăng nhập cho nguồn yêu cầu tài khoản: màn Nguồn mở WebView để user
  // tự đăng nhập; cookie lưu vào WebView dùng chung nên lần tải nền sau đó tự mang theo.
  final String? loginUrl;

  SourceAdapter({
    required this.domain,
    required this.version,
    required this.selectors,
    required this.removeSelectors,
    required this.textCleanup,
    this.searchUrl,
    this.tocApi,
    this.tocPageUrl,
    this.api,
    this.loginUrl,
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
    api: j['api'] == null
        ? null
        : SourceApi.fromJson(Map<String, dynamic>.from(j['api'] as Map)),
    loginUrl: j['loginUrl'] as String?,
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
        api: api,
        loginUrl: loginUrl,
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

  /// false khi mục lục phân trang bị lỗi một trang: danh sách có thể thủng.
  /// Nơi lưu phải giữ mục lục cũ, không ghi đè bằng danh sách thiếu.
  final bool tocComplete;

  NovelInfo({
    required this.title,
    this.coverUrl,
    required this.chapters,
    this.tocComplete = true,
  });

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
  // URL rác (không parse được) thì trả nguyên xi thay vì ném: nơi gọi dùng
  // kết quả này cho touchLibrary/tìm mục lục — có kết quả lạ vẫn tốt hơn
  // văng exception giữa đường nạp chương.
  final parsed = Uri.tryParse(url);
  if (parsed == null) return url;
  final uri = parsed.removeFragment();
  // Bỏ segment rỗng do dấu '/' cuối để không cắt nhầm vào tên chương.
  final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  if (segs.isNotEmpty) segs.removeLast();
  // URL chương kiểu /truyen/{truyen}/chuong/{chuong}: segment "chuong" nằm
  // giữa tên chương và tên truyện, bỏ thêm để ra đúng trang truyện.
  if (segs.isNotEmpty) {
    final last = segs.last.toLowerCase();
    if (last == 'chuong' || last == 'chapter' || last == 'chap') {
      segs.removeLast();
    }
  }
  final slash = url.endsWith('/') ? '/' : '';
  return uri.replace(path: '/${segs.join('/')}$slash').toString();
}

/// Chuẩn hóa URL chương để so khớp với mục lục: bỏ fragment, slash cuối,
/// host chữ thường. Màn đọc nhận URL từ location.href có thể lệch nhẹ với
/// href trong mục lục — chuẩn hóa trước khi so để không lệch một ký tự mà
/// âm thầm vô hiệu (vuốt ngang, nghe tự sang chương kế).
String normalizeChapterUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.host.isEmpty) return url.trim();
  var path = u.path;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final q = u.query.isEmpty ? '' : '?${u.query}';
  return '${u.host.toLowerCase()}$path$q';
}

/// Hai link chương có phải một chương không, bỏ khác biệt vô hại (slash cuối,
/// fragment, hoa thường tên miền, http/https). Link sách trong máy so nguyên.
bool sameChapterUrl(String? a, String? b) {
  if (a == null || b == null) return a == b;
  return normalizeChapterUrl(a) == normalizeChapterUrl(b);
}

/// Chương [chapterUrl] có thuộc truyện [storyUrl] mà màn đọc đã biết không.
/// Không suy URL truyện từ chương: đoán lệch thì sửa từ "chỉ truyện này" áp
/// nhầm hoặc không áp. Khớp khi cùng link, sách cùng mã, chương nằm trong mục
/// lục của truyện đó, hoặc link chương nằm dưới link truyện.
bool chapterBelongsToStory(
  String chapterUrl,
  String storyUrl,
  Iterable<ChapterRef> toc,
) {
  if (chapterUrl.startsWith('book:') || storyUrl.startsWith('book:')) {
    return BookUrl.storyOf(chapterUrl) == storyUrl;
  }
  if (sameChapterUrl(chapterUrl, storyUrl)) return true;
  if (toc.any((c) => sameChapterUrl(c.url, chapterUrl))) return true;
  final base = storyUrl.endsWith('/') ? storyUrl : '$storyUrl/';
  return chapterUrl.startsWith(base);
}

/// URL truyện dùng khi áp sửa từ lúc nghe. [remembered] là URL màn đọc truyền
/// lúc bấm nghe — giữ nó khi chương còn thuộc truyện đó, không đoán lại.
String storyUrlForPlayback({
  required String chapterUrl,
  required String? remembered,
  Iterable<ChapterRef> toc = const [],
}) {
  if (remembered != null &&
      chapterBelongsToStory(chapterUrl, remembered, toc)) {
    return remembered;
  }
  return storyUrlFromChapter(chapterUrl);
}

/// Mục lục web tải chưa đủ trang. Nơi lưu phải giữ danh sách cũ.
class IncompleteTocException implements Exception {
  @override
  String toString() =>
      'Mục lục tải chưa đủ vì một trang bị lỗi. Danh sách chương cũ được giữ.';
}
