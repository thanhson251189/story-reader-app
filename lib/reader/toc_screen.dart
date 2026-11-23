import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import 'reader_screen.dart';

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

  // So khớp chương đang đọc với mục lục: bỏ qua khác biệt vô hại giữa URL
  // trang chương (location.href) và href trong mục lục. Quy tắc thật nằm ở
  // normalizeChapterUrl (core/models) để bộ dữ liệu dùng chung cho fillNav.
  static String normUrl(String url) => normalizeChapterUrl(url);

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
  // URL chương đã từng mở (đã chuẩn hoá) — tô xám + dấu check.
  Set<String> _opened = {};
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
    // Rời mục lục (Back hoặc mở chương) phải dừng tải. Không có cờ này thì vòng
    // lặp vẫn tải tiếp sau khi thanh tiến độ và nút Huỷ đã biến mất.
    _dlCancel = true;
    _scroll.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  /// Nghỉ [seconds] giây, nhưng thoát trong vòng 1 giây nếu user huỷ hoặc rời màn.
  /// true = nghỉ hết; false = đã huỷ.
  Future<bool> _pause(int seconds) async {
    for (var s = 0; s < seconds && !_dlCancel; s++) {
      await Future.delayed(const Duration(seconds: 1));
    }
    return !_dlCancel;
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
        if (!info.tocComplete) throw IncompleteTocException();
        chapters = info.chapters;
        _title = info.title;
        await db.saveStoryInfo(
          widget.storyUrl,
          info,
          lastChapterUrl: widget.currentChapterUrl,
        );
      }
      final cached = await db.getCachedChapterUrls();
      final opened = await db.openedChapterUrls();
      if (!mounted) return;
      setState(() {
        _chapters = chapters;
        _cached = cached.map(TocScreen.normUrl).toSet();
        _opened = opened.map(TocScreen.normUrl).toSet();
        _loading = false;
        _numbers = [
          for (var i = 0; i < chapters.length; i++)
            WebFetcher.trailingNumber(chapters[i].url) ?? i + 1,
        ];
        _indexByUrl = {
          for (var i = 0; i < chapters.length; i++)
            TocScreen.normUrl(chapters[i].url): i,
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
        _error = friendlyError(e);
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
      final cur = TocScreen.normUrl(widget.currentChapterUrl!);
      final i = _chapters.indexWhere((c) => TocScreen.normUrl(c.url) == cur);
      if (i >= 0) start = i;
    }
    var downloaded = 0;
    var already = 0;
    var covered = 0;
    var fail = 0;
    var streak = 0;
    var challenges = 0;
    var pace = 5;
    String? lastErr;
    var i = start;
    while (i < _chapters.length && covered < count && !_dlCancel) {
      final url = _chapters[i].url;
      if (_cached.contains(TocScreen.normUrl(url))) {
        // Đã có trong máy vẫn ghim, và tính vào N chương được yêu cầu. Không
        // tính thì "Tải 5 chương tiếp" bỏ qua chương có sẵn rồi tải thêm cho
        // đủ 5 chương mới — xa hơn đoạn user vừa xin.
        await db.pinChapter(url);
        if (_dlCancel) break;
        already++;
        covered++;
        i++;
        if (mounted) setState(() => _dlDone = covered);
        continue;
      }
      final adapter = ref.read(adapterRepoProvider).forUrl(url);
      if (adapter == null) break;
      try {
        final c = await fetcher.fetchChapter(url, adapter);
        await db.cacheChapter(c);
        await db.pinChapter(url);
        downloaded++;
        if (_dlCancel) {
          if (mounted) {
            setState(() {
              _cached.add(TocScreen.normUrl(url));
              _cached.add(TocScreen.normUrl(c.url));
            });
          }
          break;
        }
        covered++;
        streak = 0;
        i++;
        if (mounted) {
          setState(() {
            _cached.add(TocScreen.normUrl(url));
            _cached.add(TocScreen.normUrl(c.url));
            _dlDone = covered;
          });
        }
      } on ChallengeException {
        fail++;
        challenges++;
        lastErr = 'trang chặn bot';
        if (challenges >= 8) break;
        // Nguồn chặn bot theo số lượt tải: nghỉ dài rồi thử lại đúng chương.
        pace = (pace + 2).clamp(5, 15);
        if (!await _pause(60)) break;
        continue;
      } catch (e) {
        fail++;
        lastErr = e.toString().replaceFirst('Exception: ', '');
        // 3 lần hỏng liên tiếp thường là bị chặn — dừng để khỏi đập tiếp.
        if (++streak >= 3) break;
        i++;
        if (!await _pause(5)) break;
      }
      if (_dlCancel) break;
      // Nhịp tối thiểu bằng prefetcher (5s) để tránh bị chặn. Nghỉ từng giây
      // để Huỷ / rời màn có hiệu lực, không chờ hết 5–15s mới dừng.
      if (covered < count && i < _chapters.length) {
        if (!await _pause(pace)) break;
      }
    }
    if (!mounted) return;
    final err = fail > 0 ? ', $fail lỗi: $lastErr' : '';
    final String msg;
    if (_dlCancel) {
      msg = downloaded > 0
          ? 'Đã huỷ, tải được $downloaded chương$err'
          : 'Đã huỷ$err';
    } else if (downloaded == 0 && already > 0 && fail == 0) {
      msg = 'Đã có đủ $already chương trong máy';
    } else if (already > 0 && downloaded > 0) {
      msg = 'Đã xong $covered chương, tải mới $downloaded$err';
    } else {
      msg = 'Đã tải $downloaded chương$err';
    }
    setState(() {
      _downloading = false;
      _dlResult = msg;
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
    final ci = _indexByUrl[TocScreen.normUrl(url)];
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
    final currentNorm = widget.currentChapterUrl == null
        ? null
        : TocScreen.normUrl(widget.currentChapterUrl!);
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
                                  currentNorm != null &&
                                  TocScreen.normUrl(c.url) == currentNorm;
                              // Chương đã từng mở: tô xám. Icon cached ưu tiên
                              // hơn vì chỉ dẫn chuyện có thể đọc offline.
                              final isRead =
                                  !isCurrent &&
                                  _opened.contains(TocScreen.normUrl(c.url));
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
                                      : (isRead
                                            ? TextStyle(
                                                color: Theme.of(context)
                                                    .colorScheme
                                                    .onSurfaceVariant,
                                              )
                                            : null),
                                ),
                                trailing: _cached.contains(TocScreen.normUrl(c.url))
                                    ? const Icon(
                                        Icons.offline_pin,
                                        size: 18,
                                        color: Colors.green,
                                      )
                                    : (isRead
                                          ? Icon(
                                              Icons.check_circle_outline,
                                              size: 18,
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .outline,
                                            )
                                          : null),
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
