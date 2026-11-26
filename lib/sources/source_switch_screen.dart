import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import '../fetcher/webview_fallback_screen.dart';
import 'registry.dart';
import 'source_login_screen.dart';
import 'source_switch.dart';

/// Kết quả màn đổi nguồn trả về màn đọc: mở chương đã ghép ở nguồn mới.
class SourceSwitchResult {
  final String storyUrl;
  final String title;
  final String chapterUrl;

  SourceSwitchResult({
    required this.storyUrl,
    required this.title,
    required this.chapterUrl,
  });
}

/// Tìm đúng truyện đang đọc trên các nguồn khác và ghép chương tương ứng.
/// Chỉ tải mục lục, chưa tải nội dung chương — màn đọc mới làm việc đó.
class SourceSwitchScreen extends ConsumerStatefulWidget {
  final String storyTitle;
  final String storyUrl;
  final String chapterUrl;
  final String chapterTitle;

  const SourceSwitchScreen({
    super.key,
    required this.storyTitle,
    required this.storyUrl,
    required this.chapterUrl,
    required this.chapterTitle,
  });

  @override
  ConsumerState<SourceSwitchScreen> createState() => _SourceSwitchScreenState();
}

class _SourceSwitchScreenState extends ConsumerState<SourceSwitchScreen> {
  late final TextEditingController _q = TextEditingController(
    text: widget.storyTitle,
  );
  int _gen = 0;
  bool _searched = false;
  String? _opening;
  final Map<String, List<SearchResult>> _results = {};
  final Map<String, String> _errors = {};
  final Set<String> _loading = {};
  Map<String, String> _names = {};
  bool _hideAdult = false;
  Set<String> _adultDomains = {};

  List<SourceAdapter> get _targets {
    final current = ref
        .read(adapterRepoProvider)
        .forUrl(widget.storyUrl)
        ?.domain;
    return SourceSwitch.availableTargets(
      adapters: ref.read(adapterRepoProvider).all,
      currentDomain: current,
      hideAdult: _hideAdult,
      adultDomains: _adultDomains,
    );
  }

  /// Màn là route riêng nên hiếm khi cài đặt đổi giữa chừng, nhưng đọc lại
  /// trước mỗi lượt tìm là rẻ và tránh tự tìm ngay lúc mở khi cờ 18+ chưa nạp.
  Future<void> _refreshAdult() async {
    final db = ref.read(appDbProvider);
    final hide = await SourceRegistry.hideAdultEnabled(db);
    final adult = await SourceRegistry.adultDomains(db);
    if (!mounted) return;
    setState(() {
      _hideAdult = hide;
      _adultDomains = adult;
    });
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadNames());
    if (widget.storyTitle.trim().isNotEmpty) unawaited(_run());
  }

  Future<void> _loadNames() async {
    final names = await loadAdapterNames(ref.read(appDbProvider));
    if (mounted) setState(() => _names = names);
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    // Nạp cờ 18+ TRƯỚC khi lấy _targets: lượt tự tìm lúc mở màn chạy trước
    // mọi await nên nếu để song song sẽ vẫn lộ nguồn 18+.
    await _refreshAdult();
    if (!mounted) return;
    final q = _q.text.trim();
    if (q.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Nhập tên truyện trước đã')));
      return;
    }
    final targets = _targets;
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chưa có nguồn khác hỗ trợ tìm kiếm')),
      );
      return;
    }
    final gen = ++_gen;
    setState(() {
      _searched = true;
      _results.clear();
      _errors.clear();
      _loading
        ..clear()
        ..addAll(targets.map((a) => a.domain));
    });
    final queue = [...targets];
    Future<void> worker() async {
      while (queue.isNotEmpty && gen == _gen) {
        final a = queue.removeAt(0);
        try {
          final r = await ref.read(webFetcherProvider).searchStories(q, a);
          if (gen != _gen || !mounted) return;
          setState(() {
            _results[a.domain] = r;
            _loading.remove(a.domain);
          });
        } catch (e) {
          if (gen != _gen || !mounted) return;
          setState(() {
            _errors[a.domain] = friendlyError(e);
            _loading.remove(a.domain);
          });
        }
      }
    }

    // Hai nguồn một lúc: đủ nhanh mà máy yếu không nghẽn WebView.
    await Future.wait([worker(), worker()]);
  }

  String _label(SourceAdapter a) => SourceRegistry.labelFor(a.domain, _names);

  Future<NovelInfo?> _fetchStory(SearchResult r, SourceAdapter a) async {
    try {
      return await ref.read(webFetcherProvider).fetchStory(r.url, a);
    } on ChallengeException {
      final map = await Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => WebViewFallbackScreen(
            url: r.url,
            extractJs: WebFetcher.storyJs(a),
          ),
        ),
      );
      if (map == null) return null;
      return WebFetcher.parseStory(map);
    }
  }

  Future<void> _pick(SearchResult r, SourceAdapter a) async {
    if (_opening != null) return;
    setState(() => _opening = r.url);
    final db = ref.read(appDbProvider);
    try {
      final info = await _fetchStory(r, a);
      if (info == null || !mounted) return;
      if (info.chapters.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nguồn này chưa trả được mục lục')),
        );
        return;
      }
      final oldToc = await db.getToc(widget.storyUrl);
      final mapped =
          SourceSwitch.mapChapter(
            oldToc: oldToc,
            currentChapterUrl: widget.chapterUrl,
            currentChapterTitle: widget.chapterTitle,
            newToc: info.chapters,
          ) ??
          info.chapters.first;
      final inLib = await db.isInLibrary(widget.storyUrl);
      final canReplace = inLib && info.tocComplete;
      if (!mounted) return;
      final replace = await showModalBottomSheet<bool>(
        context: context,
        builder: (ctx) => _confirmSheet(
          ctx,
          info: info,
          source: _label(a),
          mapped: mapped,
          inLib: inLib,
          canReplace: canReplace,
        ),
      );
      if (replace == null || !mounted) return;
      final title = info.title.trim().isEmpty
          ? (r.title.trim().isEmpty ? widget.storyTitle : r.title.trim())
          : info.title.trim();
      if (replace) {
        await db.switchLibrarySource(
          oldStoryUrl: widget.storyUrl,
          newStoryUrl: r.url,
          title: title,
          coverUrl: info.coverUrl ?? r.coverUrl,
          chapterUrl: mapped.url,
          toc: info.chapters,
        );
      }
      if (!mounted) return;
      Navigator.pop(
        context,
        SourceSwitchResult(
          storyUrl: r.url,
          title: title,
          chapterUrl: mapped.url,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không đổi được nguồn: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  Widget _confirmSheet(
    BuildContext ctx, {
    required NovelInfo info,
    required String source,
    required ChapterRef mapped,
    required bool inLib,
    required bool canReplace,
  }) {
    var replace = canReplace;
    return StatefulBuilder(
      builder: (ctx, setSheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                info.title.trim().isEmpty ? widget.storyTitle : info.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                '$source · ${info.chapters.length} chương',
                style: Theme.of(ctx).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              Text(
                'Mở: ${mapped.title}',
                style: Theme.of(ctx).textTheme.bodyMedium,
              ),
              if (inLib && !info.tocComplete)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Mục lục tải chưa đủ nên chỉ mở, không thay dòng thư viện.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ),
              if (canReplace)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Thay nguồn trong thư viện'),
                  subtitle: const Text('Giữ vị trí theo chương đã ghép'),
                  value: replace,
                  onChanged: (v) => setSheet(() => replace = v),
                ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Huỷ'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, replace),
                    child: Text(replace ? 'Thay nguồn và mở' : 'Mở chương'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets;
    return Scaffold(
      appBar: AppBar(title: const Text('Tìm truyện ở nguồn khác')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _q,
                    textInputAction: TextInputAction.search,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      hintText: 'Tên truyện',
                    ),
                    onSubmitted: (_) => _run(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: _run, child: const Text('Tìm')),
              ],
            ),
          ),
          if (_searched && targets.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Chưa cài nguồn nào khác có tìm kiếm.'),
            ),
          Expanded(
            child: !_searched
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Bấm Tìm để dò truyện này trên các nguồn đã cài.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final a in targets)
                        if (_loading.contains(a.domain) ||
                            _results.containsKey(a.domain) ||
                            _errors.containsKey(a.domain))
                          _section(a),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _section(SourceAdapter a) {
    final results = _results[a.domain];
    final error = _errors[a.domain];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(_label(a), style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(width: 8),
            if (_loading.contains(a.domain))
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (error != null)
              Icon(
                Icons.warning_amber,
                size: 16,
                color: Theme.of(context).colorScheme.error,
              )
            else if (results != null)
              Text(
                '${results.length} kết quả',
                style: Theme.of(context).textTheme.bodySmall,
              ),
          ],
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(error, style: Theme.of(context).textTheme.bodySmall),
          ),
        if (results != null && results.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              'Không thấy truyện khớp.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final r in results ?? const <SearchResult>[])
          Card(
            child: ListTile(
              title: Text(
                r.title.trim().isEmpty ? 'Không có tên' : r.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _opening == r.url
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
              onTap: _opening == null ? () => _pick(r, a) : null,
            ),
          ),
        const SizedBox(height: 12),
      ],
    );
  }
}
