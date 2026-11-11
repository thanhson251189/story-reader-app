class SourceAdapter {
  final String domain;
  final int version;
  final Map<String, String> selectors;
  final List<String> removeSelectors;
  final List<Map<String, String>> textCleanup;

  SourceAdapter({
    required this.domain,
    required this.version,
    required this.selectors,
    required this.removeSelectors,
    required this.textCleanup,
  });

  factory SourceAdapter.fromJson(Map<String, dynamic> j) => SourceAdapter(
        domain: j['domain'] as String,
        version: (j['version'] as num?)?.toInt() ?? 1,
        selectors: Map<String, String>.from(j['selectors'] as Map? ?? {}),
        removeSelectors: List<String>.from(j['removeSelectors'] as List? ?? []),
        textCleanup: (j['textCleanup'] as List? ?? [])
            .map((e) => Map<String, String>.from(e as Map))
            .toList(),
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

  factory ChapterRef.fromJson(Map<String, dynamic> j) =>
      ChapterRef(title: j['title'] as String? ?? '', url: j['url'] as String? ?? '');
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

class ChallengeException implements Exception {
  @override
  String toString() => 'Trang đang chặn bot, cần mở WebView để vượt kiểm tra';
}

class ReaderSettings {
  double fontSize;
  double lineHeight;
  String theme;

  ReaderSettings({
    this.fontSize = 20,
    this.lineHeight = 1.8,
    this.theme = 'light',
  });
}
