import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cover_image.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import '../fetcher/webview_fallback_screen.dart';
import '../reader/reader_screen.dart';

enum _Status { loading, done, error }

class _SourceState {
  _Status status = _Status.loading;
  List<SearchResult> results = [];
  String? error;
  bool blocked = false;
}

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  // null nghĩa là chọn tất cả; tập rỗng là không chọn nguồn nào.
  static Set<String>? toggleSource(
    Set<String>? picked,
    String domain,
    List<String> all,
  ) {
    final base = picked == null ? {...all} : {...picked};
    if (!base.remove(domain)) base.add(domain);
    return base.length == all.length ? null : base;
  }

  static String summary(Set<String>? picked) => picked == null
      ? 'Tất cả nguồn'
      : picked.isEmpty
      ? 'Chưa chọn nguồn'
      : picked.length == 1
      ? picked.first
      : '${picked.length} nguồn đã chọn';

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _q = TextEditingController();
  Set<String>? _picked;
  bool _pickerOpen = false;
  int _gen = 0;
  bool _searched = false;
  String? _opening;
  final Map<String, _SourceState> _states = {};

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  List<SourceAdapter> get _adapters => ref.read(adapterRepoProvider).all;

  List<SourceAdapter> get _supported =>
      _adapters.where((a) => a.searchUrl != null).toList();

  Future<void> _run() async {
    final q = _q.text.trim();
    if (q.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Nhập từ khoá trước đã')));
      return;
    }
    final picked = _picked;
    final targets = _supported
        .where((a) => picked == null || picked.contains(a.domain))
        .toList();
    if (targets.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _supported.isEmpty
                ? 'Chưa có nguồn nào hỗ trợ tìm kiếm'
                : 'Chưa chọn nguồn nào để tìm',
          ),
        ),
      );
      return;
    }
    final gen = ++_gen;
    setState(() {
      _searched = true;
      _pickerOpen = false;
      _states.clear();
      for (final a in targets) {
        _states[a.domain] = _SourceState();
      }
    });
    final queue = [...targets];
    Future<void> worker() async {
      while (queue.isNotEmpty && gen == _gen) {
        final a = queue.removeAt(0);
        try {
          final r = await ref.read(webFetcherProvider).searchStories(q, a);
          if (gen != _gen || !mounted) return;
          setState(() {
            _states[a.domain]!
              ..status = _Status.done
              ..results = r;
          });
        } catch (e) {
          if (gen != _gen || !mounted) return;
          setState(() {
            _states[a.domain]!
              ..status = _Status.error
              ..blocked = e is ChallengeException
              ..error = e.toString().replaceFirst('Exception: ', '');
          });
        }
      }
    }

    // Mỗi nguồn một headless webview; giới hạn 2 để máy yếu không nghẽn.
    await Future.wait([worker(), worker()]);
  }

  Future<Map<String, dynamic>?> _viaWebView(String url, String js) =>
      Navigator.push<Map<String, dynamic>>(
        context,
        MaterialPageRoute(
          builder: (_) => WebViewFallbackScreen(url: url, extractJs: js),
        ),
      );

  Future<void> _searchViaWebView(SourceAdapter a) async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    final map = await _viaWebView(
      WebFetcher.searchUrlFor(a, q),
      WebFetcher.searchJs(a),
    );
    if (map == null || !mounted) return;
    setState(() {
      _states[a.domain]!
        ..status = _Status.done
        ..blocked = false
        ..results = WebFetcher.parseSearch(map);
    });
  }

  Future<void> _openStory(SearchResult r, SourceAdapter a) async {
    if (_opening != null) return;
    setState(() => _opening = r.url);
    try {
      NovelInfo info;
      try {
        info = await ref.read(webFetcherProvider).fetchStory(r.url, a);
      } on ChallengeException {
        final map = await _viaWebView(r.url, WebFetcher.storyJs(a));
        if (map == null || !mounted) return;
        info = WebFetcher.parseStory(map);
      }
      final lib = await ref.read(appDbProvider).getLibrary();
      final last = lib
          .where((e) => e['story_url'] == r.url)
          .map((e) => e['last_chapter_url'] as String?)
          .firstOrNull;
      // Trang không có danh sách chương thì mở thẳng nó như một chương.
      final url =
          last ?? (info.chapters.isEmpty ? r.url : info.chapters.first.url);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(url: url, storyUrl: r.url),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Không mở được truyện: ${e.toString().replaceFirst('Exception: ', '')}',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final unsupported = _adapters.where((a) => a.searchUrl == null).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Tìm kiếm')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextField(
              controller: _q,
              textInputAction: TextInputAction.search,
              autocorrect: false,
              decoration: InputDecoration(
                hintText: 'Tên truyện, tác giả...',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _q.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Xoá từ khoá',
                        onPressed: () => setState(() => _q.clear()),
                      ),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _run(),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: () => setState(() => _pickerOpen = !_pickerOpen),
              icon: Icon(
                _pickerOpen ? Icons.arrow_drop_up : Icons.arrow_drop_down,
              ),
              label: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  SearchScreen.summary(_picked),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
          if (_pickerOpen)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Card(
                margin: EdgeInsets.zero,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 320),
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    children: [
                      CheckboxListTile(
                        dense: true,
                        title: const Text('Tất cả nguồn'),
                        value: _picked == null,
                        onChanged: (v) => setState(
                          () => _picked = v == true ? null : <String>{},
                        ),
                      ),
                      for (final a in _supported)
                        CheckboxListTile(
                          dense: true,
                          title: Text(a.domain),
                          value: _picked == null || _picked!.contains(a.domain),
                          onChanged: (_) => setState(() {
                            _picked = SearchScreen.toggleSource(
                              _picked,
                              a.domain,
                              _supported.map((x) => x.domain).toList(),
                            );
                          }),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          if (unsupported.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                'Chưa hỗ trợ tìm: ${unsupported.map((a) => a.domain).join(', ')}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          Expanded(
            child: !_searched
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.travel_explore,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Tìm truyện trong các nguồn',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Nhập từ khoá rồi bấm tìm. Chọn một nguồn '
                            'hoặc để Tất cả để tìm song song.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final a in _adapters.where(
                        (x) => _states.containsKey(x.domain),
                      ))
                        _sourceSection(a),
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _run,
        icon: const Icon(Icons.search),
        label: const Text('Tìm'),
      ),
    );
  }

  Widget _sourceSection(SourceAdapter a) {
    final s = _states[a.domain]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Text(a.domain, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(width: 8),
              if (s.status == _Status.loading)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else if (s.status == _Status.done)
                Text(
                  '${s.results.length} kết quả',
                  style: Theme.of(context).textTheme.bodySmall,
                )
              else
                Icon(
                  Icons.warning_amber,
                  size: 16,
                  color: Theme.of(context).colorScheme.error,
                ),
            ],
          ),
        ),
        if (s.status == _Status.error)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Nguồn này không trả kết quả: ${s.error}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  if (s.blocked)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: () => _searchViaWebView(a),
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('Mở WebView'),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (s.status == _Status.done && s.results.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Không tìm thấy truyện khớp.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        for (final r in s.results)
          Card(
            child: ListTile(
              leading: CoverImage(url: r.coverUrl, width: 40, height: 56),
              title: Text(
                r.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                Uri.tryParse(r.url)?.path ?? r.url,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: _opening == r.url
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
              onTap: () => _openStory(r, a),
            ),
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}
