import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import 'reader_screen.dart';

String storyUrlFromChapter(String url) {
  if (url.startsWith('book:')) {
    final parts = url.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : url;
  }
  final uri = Uri.parse(url);
  final segs = [...uri.pathSegments];
  if (segs.isNotEmpty) segs.removeLast();
  return uri.replace(path: '/${segs.join('/')}').toString();
}

class TocScreen extends ConsumerStatefulWidget {
  final String storyUrl;
  final String? currentChapterUrl;
  const TocScreen({super.key, required this.storyUrl, this.currentChapterUrl});

  static String chapterLabel(String title, int number) {
    final t = title.trim();
    if (RegExp(r'^(chương|chapter)\b', caseSensitive: false).hasMatch(t)) {
      return t;
    }
    final rest = t.replaceFirst(RegExp(r'^\d+(?:\s*[:.,\-–]|\s*\n)\s*'), '');
    return rest.isEmpty ? 'Chương $number' : 'Chương $number: $rest';
  }

  static final Map<String, String> _foldMap = () {
    const from =
        'àáảãạăắằẳẵặâấầẩẫậèéẻẽẹêếềểễệìíỉĩịòóỏõọôốồổỗộơớờởỡợùúủũụưứừửữựỳýỷỹỵđ';
    const to =
        'aaaaaaaaaaaaaaaaaeeeeeeeeeeeiiiiiooooooooooooooooouuuuuuuuuuuyyyyyd';
    return {for (var i = 0; i < from.length; i++) from[i]: to[i]};
  }();

  static String fold(String s) {
    final b = StringBuffer();
    for (final r in s.toLowerCase().runes) {
      final c = String.fromCharCode(r);
      b.write(_foldMap[c] ?? c);
    }
    return b.toString();
  }

  @override
  ConsumerState<TocScreen> createState() => _TocScreenState();
}

class _TocScreenState extends ConsumerState<TocScreen> {
  static const _row = 48.0;

  List<ChapterRef> _chapters = [];
  List<int> _numbers = [];
  Map<String, int> _indexByUrl = {};
  List<int> _view = [];
  Set<String> _cached = {};
  bool _loading = true;
  String? _error;
  String? _title;
  bool _downloading = false;
  bool _dlCancel = false;
  int _dlDone = 0;
  int _dlTotal = 0;
  String? _dlResult;
  bool _desc = false;
  String _query = '';
  final ScrollController _scroll = ScrollController();
  final TextEditingController _filterCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    if (force) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final db = ref.read(appDbProvider);
    var chapters = force ? <ChapterRef>[] : await db.getToc(widget.storyUrl);
    try {
      if (chapters.isEmpty) {
        final adapter = ref.read(adapterRepoProvider).forUrl(widget.storyUrl);
        if (adapter == null) throw Exception('Chưa có adapter cho trang này');
        final info = await ref
            .read(webFetcherProvider)
            .fetchStory(widget.storyUrl, adapter);
        chapters = info.chapters;
        _title = info.title;
        await db.saveToc(widget.storyUrl, chapters);
        await db.upsertLibrary(
          storyUrl: widget.storyUrl,
          title: info.title,
          coverUrl: info.coverUrl,
          lastChapterUrl: widget.currentChapterUrl,
        );
      }
      final cached = await db.getCachedChapterUrls();
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _cached = cached;
        _loading = false;
        _numbers = [
          for (var i = 0; i < chapters.length; i++)
            WebFetcher.trailingNumber(chapters[i].url) ?? i + 1,
        ];
        _indexByUrl = {
          for (var i = 0; i < chapters.length; i++) chapters[i].url: i,
        };
        _rebuildView();
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _jumpToCurrent();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _downloadAhead(int count) async {
    if (_downloading || _chapters.isEmpty) return;
    setState(() {
      _downloading = true;
      _dlCancel = false;
      _dlDone = 0;
      _dlTotal = count;
      _dlResult = null;
    });
    final db = ref.read(appDbProvider);
    final fetcher = ref.read(webFetcherProvider);
    var start = 0;
    if (widget.currentChapterUrl != null) {
      final i = _chapters.indexWhere((c) => c.url == widget.currentChapterUrl);
      if (i >= 0) start = i;
    }
    var ok = 0;
    var fail = 0;
    var streak = 0;
    var challenges = 0;
    var pace = 5;
    String? lastErr;
    var i = start;
    while (i < _chapters.length && ok < count && !_dlCancel) {
      final url = _chapters[i].url;
      if (_cached.contains(url)) {
        i++;
        continue;
      }
      final adapter = ref.read(adapterRepoProvider).forUrl(url);
      if (adapter == null) break;
      try {
        final c = await fetcher.fetchChapter(url, adapter);
        await db.cacheChapter(c);
        ok++;
        streak = 0;
        i++;
        if (mounted) {
          setState(() {
            _cached.add(url);
            _dlDone = ok;
          });
        }
      } on ChallengeException {
        fail++;
        challenges++;
        lastErr = 'trang chặn bot';
        if (challenges >= 8) break;
        // Nguồn chặn bot theo số lượt tải: nghỉ dài rồi thử lại đúng chương.
        pace = (pace + 2).clamp(5, 15);
        for (var s = 0; s < 60 && !_dlCancel; s++) {
          await Future.delayed(const Duration(seconds: 1));
        }
        continue;
      } catch (e) {
        fail++;
        lastErr = e.toString().replaceFirst('Exception: ', '');
        // 3 lần hỏng liên tiếp thường là bị chặn — dừng để khỏi đập tiếp.
        if (++streak >= 3) break;
        i++;
        await Future.delayed(const Duration(seconds: 5));
      }
      // Nhịp tối thiểu bằng prefetcher (5s) để tránh bị chặn.
      if (!_dlCancel && ok < count) {
        await Future.delayed(Duration(seconds: pace));
      }
    }
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _dlResult =
          'Đã tải $ok chương'
          '${fail > 0 ? ', $fail lỗi: $lastErr' : ''}'
          '${_dlCancel ? ' (đã huỷ)' : ''}';
    });
  }

  String _label(int i) =>
      TocScreen.chapterLabel(_chapters[i].title, _numbers[i]);

  void _rebuildView() {
    var idx = List<int>.generate(_chapters.length, (i) => i);
    if (_desc) idx = idx.reversed.toList();
    final q = _query.trim();
    if (q.isNotEmpty) {
      final f = TocScreen.fold(q);
      idx = idx
          .where(
            (i) =>
                '${_numbers[i]}'.contains(q) ||
                TocScreen.fold(_label(i)).contains(f),
          )
          .toList();
    }
    _view = idx;
  }

  void _jumpToCurrent() {
    final url = widget.currentChapterUrl;
    if (url == null || !_scroll.hasClients) return;
    final ci = _indexByUrl[url];
    if (ci == null) return;
    final vi = _view.indexOf(ci);
    if (vi < 0) return;
    _scroll.jumpTo(
      (vi * _row - 2 * _row).clamp(0.0, _scroll.position.maxScrollExtent),
    );
  }

  void _toggleSort() {
    final top = _view.isEmpty
        ? null
        : _view[(_scroll.hasClients ? _scroll.offset / _row : 0).floor().clamp(
            0,
            _view.length - 1,
          )];
    setState(() {
      _desc = !_desc;
      _rebuildView();
    });
    if (top == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final vi = _view.indexOf(top);
      if (vi >= 0) {
        _scroll.jumpTo(
          (vi * _row).clamp(0.0, _scroll.position.maxScrollExtent),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _title ?? 'Mục lục',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: Icon(_desc ? Icons.arrow_downward : Icons.arrow_upward),
            tooltip: 'Đảo thứ tự chương',
            onPressed: _chapters.isEmpty ? null : _toggleSort,
          ),
          if (!widget.storyUrl.startsWith('book:')) ...[
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Làm mới mục lục',
              onPressed: _loading || _downloading
                  ? null
                  : () => _load(force: true),
            ),
            PopupMenuButton<int>(
              icon: _downloading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              tooltip: 'Tải trước chương',
              enabled: !_downloading,
              onSelected: _downloadAhead,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 5, child: Text('Tải 5 chương tiếp')),
                PopupMenuItem(value: 50, child: Text('Tải 50 chương tiếp')),
                PopupMenuItem(value: 100, child: Text('Tải 100 chương tiếp')),
              ],
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _load,
                      child: const Text('Thử lại'),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              children: [
                if (_downloading)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: LinearProgressIndicator(
                            value: _dlTotal == 0 ? null : _dlDone / _dlTotal,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text('$_dlDone/$_dlTotal'),
                        TextButton(
                          onPressed: () => setState(() => _dlCancel = true),
                          child: const Text('Huỷ'),
                        ),
                      ],
                    ),
                  ),
                if (_dlResult != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _dlResult!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 18),
                          tooltip: 'Ẩn kết quả tải',
                          onPressed: () => setState(() => _dlResult = null),
                        ),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    controller: _filterCtrl,
                    onChanged: (v) => setState(() {
                      _query = v;
                      _rebuildView();
                    }),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      prefixIconConstraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      hintText: 'Lọc theo số hoặc tên chương',
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              tooltip: 'Xóa bộ lọc',
                              onPressed: () => setState(() {
                                _filterCtrl.clear();
                                _query = '';
                                _rebuildView();
                              }),
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: _view.isEmpty
                      ? const Center(child: Text('Không có chương khớp bộ lọc'))
                      : Scrollbar(
                          controller: _scroll,
                          thumbVisibility: true,
                          interactive: true,
                          thickness: 6,
                          radius: const Radius.circular(3),
                          child: ListView.builder(
                            controller: _scroll,
                            itemExtent: _row,
                            itemCount: _view.length,
                            itemBuilder: (_, vi) {
                              final i = _view[vi];
                              final c = _chapters[i];
                              final isCurrent =
                                  c.url == widget.currentChapterUrl;
                              return ListTile(
                                dense: true,
                                title: Text(
                                  _label(i),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: isCurrent
                                      ? TextStyle(
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                          fontWeight: FontWeight.bold,
                                        )
                                      : null,
                                ),
                                trailing: _cached.contains(c.url)
                                    ? const Icon(
                                        Icons.offline_pin,
                                        size: 18,
                                        color: Colors.green,
                                      )
                                    : null,
                                onTap: () => Navigator.pushReplacement(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ReaderScreen(
                                      url: c.url,
                                      storyUrl: widget.storyUrl,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}
