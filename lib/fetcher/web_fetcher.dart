import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../core/models.dart';

class WebFetcher {
  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; CPH2629) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  static InAppWebViewSettings get settings => InAppWebViewSettings(
    javaScriptEnabled: true,
    domStorageEnabled: true,
    databaseEnabled: true,
    cacheEnabled: true,
    userAgent: _ua,
  );

  static String chapterJs(SourceAdapter a) {
    final sel = jsonEncode(a.selectors);
    final remove = jsonEncode(a.removeSelectors);
    return '''
(function(){
  const sel = $sel;
  const remove = $remove;
  const abs = h => h ? new URL(h, location.href).href : null;
  const q = s => s ? document.querySelector(s) : null;
  const n = q(sel.nextLink), p = q(sel.prevLink);
  const t = q(sel.chapterTitle);
  const title = t ? t.innerText.trim() : document.title.split('|')[0].trim();
  remove.forEach(s => { try { document.querySelectorAll(s).forEach(e => e.remove()); } catch(_){} });
  const c = q(sel.content);
  let ps = [];
  if (c) {
    ps = Array.from(c.querySelectorAll('p')).map(p => p.innerText.trim()).filter(Boolean);
    if (!ps.length) ps = c.innerText.split(/\\n{2,}/).map(t => t.trim()).filter(Boolean);
  }
  return JSON.stringify({
    url: location.href,
    title: title,
    paragraphs: ps,
    nextUrl: n ? abs(n.getAttribute('href')) : null,
    prevUrl: p ? abs(p.getAttribute('href')) : null
  });
})()
''';
  }

  static String storyJs(SourceAdapter a) {
    final sel = jsonEncode(a.selectors);
    return '''
(function(){
  const sel = $sel;
  const abs = h => h ? new URL(h, location.href).href : null;
  const q = s => s ? document.querySelector(s) : null;
  const seen = {};
  const chapters = [];
  document.querySelectorAll(sel.chapterList || 'a').forEach(a => {
    const u = abs(a.getAttribute('href'));
    if (u && !seen[u]) { seen[u] = 1; chapters.push({title: a.innerText.trim(), url: u}); }
  });
  const t = q(sel.storyTitle), cov = q(sel.cover), c = q(sel.content);
  return JSON.stringify({
    url: location.href,
    title: t ? t.innerText.trim() : document.title.split('|')[0].trim(),
    coverUrl: cov ? abs(cov.getAttribute('src')) : null,
    hasContent: !!(c && c.innerText.trim()),
    chapters: chapters
  });
})()
''';
  }

  static String searchUrlFor(SourceAdapter a, String query) =>
      a.searchUrl!.replaceAll('{query}', Uri.encodeComponent(query));

  static String searchJs(SourceAdapter a) {
    final sel = jsonEncode(a.selectors);
    return '''
(function(){
  const sel = $sel;
  const abs = h => h ? new URL(h, location.href).href : null;
  const seen = {};
  const results = [];
  document.querySelectorAll(sel.searchList || 'a').forEach(el => {
    const link = el.tagName === 'A' ? el : el.querySelector('a');
    if (!link) return;
    const u = abs(link.getAttribute('href'));
    if (!u || seen[u]) return;
    seen[u] = 1;
    const t = el.querySelector(sel.searchTitle || 'h3') || link;
    const img = el.querySelector('img');
    results.push({
      title: t.innerText.trim(),
      url: u,
      coverUrl: img ? abs(img.getAttribute('src')) : null
    });
  });
  return JSON.stringify({results: results});
})()
''';
  }

  Future<List<SearchResult>> searchStories(
    String query,
    SourceAdapter a,
  ) async {
    final map = await _fetch(
      searchUrlFor(a, query),
      searchJs(a),
      ok: (m) => m.containsKey('results'),
    );
    return parseSearch(map);
  }

  static List<SearchResult> parseSearch(Map<String, dynamic> map) =>
      (map['results'] as List? ?? [])
          .map(
            (e) => SearchResult.fromJson(Map<String, dynamic>.from(e as Map)),
          )
          .where((r) => r.title.isNotEmpty && r.url.isNotEmpty)
          .toList();

  Future<ChapterContent> fetchChapter(String url, SourceAdapter adapter) async {
    final map = await _fetch(url, chapterJs(adapter));
    final c = ChapterContent.fromJson(map);
    return ChapterContent(
      url: c.url,
      title: c.title,
      paragraphs: c.paragraphs
          .map(adapter.clean)
          .where((p) => p.isNotEmpty)
          .toList(),
      nextUrl: c.nextUrl,
      prevUrl: c.prevUrl,
    );
  }

  Future<NovelInfo> fetchStory(String url, SourceAdapter adapter) async {
    final map = await _fetch(
      url,
      storyJs(adapter),
      // Trang đơn (wikisource) không có danh sách chương nhưng vẫn có nội dung;
      // chỉ coi là chặn bot khi cả chương lẫn nội dung đều trống.
      ok: (m) =>
          (m['chapters'] as List? ?? []).isNotEmpty || m['hasContent'] == true,
    );
    return parseStory(map);
  }

  static NovelInfo parseStory(Map<String, dynamic> map) {
    final info = NovelInfo.fromJson(map);
    return NovelInfo(
      title: info.title,
      coverUrl: info.coverUrl,
      chapters: sortChapters(info.chapters),
    );
  }

  // Chỉ sort khi mọi URL đều có số đuôi; site không đánh số thì giữ thứ tự trang
  // (List.sort của Dart không ổn định, comparator trả 0 sẽ xáo trộn thứ tự).
  static List<ChapterRef> sortChapters(List<ChapterRef> chapters) {
    int? trailingNum(String u) {
      final ms = RegExp(r'\d+').allMatches(u);
      return ms.isEmpty ? null : int.tryParse(ms.last.group(0)!);
    }

    final nums = chapters.map((c) => trailingNum(c.url)).toList();
    if (nums.any((n) => n == null)) return chapters;
    final out = [...chapters];
    out.sort((x, y) => trailingNum(x.url)!.compareTo(trailingNum(y.url)!));
    return out;
  }

  Future<Map<String, dynamic>> _fetch(
    String url,
    String js, {
    bool Function(Map<String, dynamic>)? ok,
  }) async {
    final accept = ok ?? (m) => (m['paragraphs'] as List? ?? []).isNotEmpty;
    final completer = Completer<Map<String, dynamic>>();
    var done = false;
    Timer? timeout;
    HeadlessInAppWebView? wv;

    void finish(Map<String, dynamic>? data, [Object? err]) {
      if (done) return;
      done = true;
      timeout?.cancel();
      if (completer.isCompleted) return;
      if (data != null) {
        completer.complete(data);
      } else {
        completer.completeError(err ?? ChallengeException());
      }
    }

    wv = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(url: WebUri(url)),
      initialSettings: settings,
      onLoadStop: (controller, u) async {
        for (var i = 0; i < 8 && !done; i++) {
          await Future.delayed(Duration(milliseconds: i == 0 ? 700 : 1500));
          if (done) break;
          try {
            final r = await controller.evaluateJavascript(source: js);
            if (r is String && r.isNotEmpty) {
              final map = jsonDecode(r) as Map<String, dynamic>;
              if (accept(map)) {
                finish(map);
                break;
              }
            }
          } catch (_) {}
        }
        if (!done) finish(null, ChallengeException());
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) {
          finish(null, Exception('Lỗi mạng: ${error.description}'));
        }
      },
    );
    timeout = Timer(
      const Duration(seconds: 45),
      () => finish(null, TimeoutException('Quá thời gian tải trang')),
    );
    await wv.run();
    try {
      return await completer.future;
    } finally {
      try {
        await wv.dispose();
      } catch (_) {}
    }
  }
}
