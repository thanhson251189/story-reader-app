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
  remove.forEach(s => { try { document.querySelectorAll(s).forEach(e => e.remove()); } catch(_){} });
  const abs = h => h ? new URL(h, location.href).href : null;
  const q = s => s ? document.querySelector(s) : null;
  const c = q(sel.content);
  let ps = [];
  if (c) {
    ps = Array.from(c.querySelectorAll('p')).map(p => p.innerText.trim()).filter(Boolean);
    if (!ps.length) ps = c.innerText.split(/\\n{2,}/).map(t => t.trim()).filter(Boolean);
  }
  const n = q(sel.nextLink), p = q(sel.prevLink);
  return JSON.stringify({
    url: location.href,
    title: document.title.split('|')[0].trim(),
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
  const t = q(sel.storyTitle), cov = q(sel.cover);
  return JSON.stringify({
    url: location.href,
    title: t ? t.innerText.trim() : document.title.split('|')[0].trim(),
    coverUrl: cov ? abs(cov.getAttribute('src')) : null,
    chapters: chapters
  });
})()
''';
  }

  Future<ChapterContent> fetchChapter(String url, SourceAdapter adapter) async {
    final map = await _fetch(url, chapterJs(adapter));
    final c = ChapterContent.fromJson(map);
    return ChapterContent(
      url: c.url,
      title: c.title,
      paragraphs: c.paragraphs.map(adapter.clean).where((p) => p.isNotEmpty).toList(),
      nextUrl: c.nextUrl,
      prevUrl: c.prevUrl,
    );
  }

  Future<NovelInfo> fetchStory(String url, SourceAdapter adapter) async {
    final map = await _fetch(url, storyJs(adapter));
    final info = NovelInfo.fromJson(map);
    final chapters = [...info.chapters];
    int? trailingNum(String u) {
      final ms = RegExp(r'\d+').allMatches(u);
      return ms.isEmpty ? null : int.tryParse(ms.last.group(0)!);
    }
    chapters.sort((x, y) {
      final nx = trailingNum(x.url), ny = trailingNum(y.url);
      if (nx == null || ny == null) return 0;
      return nx.compareTo(ny);
    });
    return NovelInfo(url: info.url, title: info.title, coverUrl: info.coverUrl, chapters: chapters);
  }

  Future<Map<String, dynamic>> _fetch(String url, String js) async {
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
              final ps = map['paragraphs'] as List?;
              final ch = map['chapters'] as List?;
              if ((ps != null && ps.isNotEmpty) || (ch != null && ch.isNotEmpty)) {
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
    timeout = Timer(const Duration(seconds: 45),
        () => finish(null, TimeoutException('Quá thời gian tải trang')));
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