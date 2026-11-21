import 'dart:async';
import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:html/dom.dart' as html_dom;
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

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
  const abs = h => (h && h !== '#') ? new URL(h, location.href).href : null;
  const q = s => s ? document.querySelector(s) : null;
  const n = q(sel.nextLink), p = q(sel.prevLink);
  const t = q(sel.chapterTitle);
  const title = t ? t.innerText.trim() : document.title.split('|')[0].trim();
  remove.forEach(s => { try { document.querySelectorAll(s).forEach(e => e.remove()); } catch(_){} });
  const c = q(sel.content);
  let ps = [];
  if (c) {
    // Nhiều site nhét cả chương vào một <p> dài ngăn cách bằng <br>: nội dung
    // innerText lúc đó xuống từng dòng, tách theo dòng mới thành các đoạn.
    ps = Array.from(c.querySelectorAll('p')).map(p => p.innerText.trim())
      .flatMap(t => t.split(/\\n+/))
      .map(t => t.trim()).filter(Boolean);
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

  // Làm sạch chương bóc từ WebView (headless hoặc fallback thủ công):
  // áp textCleanup theo adapter và bỏ đoạn rỗng.
  static ChapterContent cleanChapter(ChapterContent c, SourceAdapter a) =>
      ChapterContent(
        url: c.url,
        title: c.title,
        paragraphs: c.paragraphs
            .map(a.clean)
            .where((p) => p.isNotEmpty)
            .toList(),
        nextUrl: c.nextUrl,
        prevUrl: c.prevUrl,
      );

  Future<ChapterContent> fetchChapter(String url, SourceAdapter adapter) async {
    final map = await _fetch(url, chapterJs(adapter));
    return cleanChapter(ChapterContent.fromJson(map), adapter);
  }

  Future<NovelInfo> fetchStory(String url, SourceAdapter adapter) async {
    final api = adapter.tocApi;
    if (api != null) {
      try {
        final info = await _fetchStoryApi(url, api);
        if (info != null) return info;
      } catch (_) {
        // API hỏng/chặn bot: rơi về quét DOM như cũ.
      }
    }
    if (adapter.tocPageUrl != null) {
      try {
        final info = await _fetchStoryHtmlPages(url, adapter);
        if (info != null) return info;
      } catch (_) {
        // Phân trang HTML hỏng: rơi về quét DOM WebView như cũ.
      }
    }
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

  static String slugOf(String url) {
    final segs = Uri.parse(url).pathSegments.where((s) => s.isNotEmpty);
    return segs.isEmpty ? '' : segs.last;
  }

  static String fillUrl(String tpl, Map<String, String> vars) {
    var out = tpl;
    vars.forEach((k, v) => out = out.replaceAll('{$k}', v));
    return out;
  }

  // Cookie người dùng đã đăng nhập qua WebView của nguồn (màn "Đăng nhập" ở
  // màn Nguồn) mang sang các request HTTP thuần — đường WebView tự có sẵn vì
  // cùng profile. Lỗi thì bỏ qua: nguồn không cần đăng nhập vẫn tải bình thường.
  Future<Map<String, String>> _headersFor(String url) async {
    final headers = {'User-Agent': _ua};
    try {
      final cookies = await CookieManager.instance()
          .getCookies(url: WebUri(url));
      final header = cookies
          .where((c) => c.name.isNotEmpty && c.value.isNotEmpty)
          .map((c) => '${c.name}=${c.value}')
          .join('; ');
      if (header.isNotEmpty) headers['Cookie'] = header;
    } catch (_) {}
    return headers;
  }

  Future<Map<String, dynamic>> _getJson(String url) async {
    final res = await http
        .get(Uri.parse(url), headers: await _headersFor(url))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<NovelInfo?> _fetchStoryApi(String url, TocApi api) async {
    final slug = slugOf(url);
    if (slug.isEmpty) return null;
    final vars = {'slug': slug};
    final novel = await _getJson(fillUrl(api.novelUrl, vars));
    final pages = <Map<String, dynamic>>[];
    var page = 1;
    var total = 0;
    var got = 0;
    do {
      final m = await _getJson(
        fillUrl(api.listUrl, {...vars, 'page': '$page'}),
      );
      pages.add(m);
      total = (m['total'] as num?)?.toInt() ?? 0;
      final n = (m['items'] as List? ?? []).length;
      got += n;
      if (n == 0) break;
      page++;
    } while (got < total && page <= 500);
    final chapters = chaptersFromApi(pages, api.chapterUrl, slug);
    if (chapters.isEmpty) return null;
    return novelFromApi(
      novel,
      chapters,
      Uri.parse(fillUrl(api.novelUrl, vars)),
    );
  }

  static List<ChapterRef> chaptersFromApi(
    List<Map<String, dynamic>> pages,
    String chapterUrlTpl,
    String slug,
  ) {
    final byNumber = <int, ChapterRef>{};
    for (final m in pages) {
      for (final e in (m['items'] as List? ?? [])) {
        final item = Map<String, dynamic>.from(e as Map);
        final n = (item['chapter_number'] as num?)?.toInt();
        if (n == null || byNumber.containsKey(n)) continue;
        final title = (item['title'] as String? ?? '').trim();
        byNumber[n] = ChapterRef(
          title: title.isEmpty ? 'Chương $n' : title,
          url: fillUrl(chapterUrlTpl, {'slug': slug, 'number': '$n'}),
        );
      }
    }
    final nums = byNumber.keys.toList()..sort();
    return [for (final n in nums) byNumber[n]!];
  }

  static NovelInfo? novelFromApi(
    Map<String, dynamic> novel,
    List<ChapterRef> chapters,
    Uri base,
  ) {
    final title = (novel['title'] as String? ?? '').trim();
    if (title.isEmpty) return null;
    final cover = novel['image_url'] as String?;
    return NovelInfo(
      title: title,
      coverUrl: cover == null || cover.isEmpty
          ? null
          : base.resolve(cover).toString(),
      chapters: chapters,
    );
  }

  Future<html_dom.Document> _getHtml(String url) async {
    final res = await http
        .get(Uri.parse(url), headers: await _headersFor(url))
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    return html_parser.parse(res.body);
  }

  // Mục lục phân trang HTML (SSR): tải song song qua HTTP, không cần WebView.
  Future<NovelInfo?> _fetchStoryHtmlPages(String url, SourceAdapter a) async {
    final tpl = a.tocPageUrl!;
    final slug = slugOf(url);
    final listSel = a.selectors['chapterList'];
    if (slug.isEmpty || listSel == null) return null;
    final base = Uri.parse(url);
    final doc = await _getHtml(url);
    final chapters = _chaptersFromDoc(doc, listSel, base);
    if (chapters.isEmpty) return null;
    final titleSel = a.selectors['storyTitle'];
    final titleEl = titleSel == null ? null : doc.querySelector(titleSel);
    final titleText = titleEl?.text.trim() ?? '';
    final title = titleText.isNotEmpty
        ? titleText
        : (doc.querySelector('title')?.text.split('|').first.trim() ?? slug);
    final coverSel = a.selectors['cover'];
    final coverEl = coverSel == null ? null : doc.querySelector(coverSel);
    final coverSrc = coverEl?.attributes['src'];
    final cover = coverSrc == null || coverSrc.isEmpty
        ? null
        : base.resolve(coverSrc).toString();
    final maxPage = _maxTocPage(doc, tpl, slug, base);
    final all = <ChapterRef>[...chapters];
    if (maxPage > 1) {
      const concurrency = 6;
      final pages = [for (var p = 2; p <= maxPage; p++) p];
      for (var i = 0; i < pages.length; i += concurrency) {
        final batch = pages.skip(i).take(concurrency).toList();
        final results = await Future.wait(
          batch.map(
            (p) => _pageChapters(
              fillUrl(tpl, {'slug': slug, 'page': '$p'}),
              listSel,
              base,
            ),
          ),
        );
        for (final r in results) {
          all.addAll(r);
        }
      }
    }
    final seen = <String>{};
    final unique = <ChapterRef>[];
    for (final c in all) {
      if (seen.add(c.url)) unique.add(c);
    }
    return NovelInfo(
      title: title,
      coverUrl: cover,
      chapters: sortChapters(unique),
    );
  }

  Future<List<ChapterRef>> _pageChapters(
    String url,
    String sel,
    Uri base,
  ) async {
    // Thử tối đa 2 lần: mạng vặt hay lỗi nửa chừng, lần 2 thường ăn ngay.
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        return _chaptersFromDoc(await _getHtml(url), sel, base);
      } catch (_) {}
    }
    return [];
  }

  static List<ChapterRef> _chaptersFromDoc(
    html_dom.Document doc,
    String sel,
    Uri base,
  ) {
    final out = <ChapterRef>[];
    final seen = <String>{};
    for (final el in doc.querySelectorAll(sel)) {
      final href = el.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final u = base.resolve(href).toString();
      if (!seen.add(u)) continue;
      final title = el.text.trim().replaceAll(RegExp(r'\s+'), ' ');
      out.add(ChapterRef(title: title, url: u));
    }
    return out;
  }

  // Số trang cuối = số lớn nhất trong các link phân trang khớp template.
  static int _maxTocPage(
    html_dom.Document doc,
    String tpl,
    String slug,
    Uri base,
  ) {
    final parts = tpl.split('{page}');
    final prefix = parts.first.replaceAll('{slug}', slug);
    final suffix = parts.length > 1 ? parts.last : '';
    var max = 1;
    for (final el in doc.querySelectorAll('a[href]')) {
      final href = el.attributes['href'];
      if (href == null) continue;
      final abs = base.resolve(href).toString();
      if (!abs.startsWith(prefix) || !abs.endsWith(suffix)) continue;
      if (abs.length <= prefix.length + suffix.length) continue;
      final n = int.tryParse(
        abs.substring(prefix.length, abs.length - suffix.length),
      );
      if (n != null && n > max) max = n;
    }
    return max > 500 ? 500 : max;
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
    final nums = chapters.map((c) => trailingNumber(c.url)).toList();
    if (nums.any((n) => n == null)) return chapters;
    final out = [...chapters];
    out.sort(
      (x, y) => trailingNumber(x.url)!.compareTo(trailingNumber(y.url)!),
    );
    return out;
  }

  static int? trailingNumber(String url) {
    final ms = RegExp(r'\d+').allMatches(url);
    return ms.isEmpty ? null : int.tryParse(ms.last.group(0)!);
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
