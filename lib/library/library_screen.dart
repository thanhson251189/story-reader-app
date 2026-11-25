import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cover_image.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/story_downloader.dart';
import '../fetcher/web_fetcher.dart';
import '../home/open_actions.dart';
import '../reader/reader_screen.dart';
import '../reader/toc_screen.dart';
import '../sources/registry.dart';
import 'library_checker.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  final bool active;
  const LibraryScreen({super.key, required this.active});

  static String? newBadge(
    String? latestUrl,
    String? latestTitle,
    String? lastUrl,
  ) {
    if (latestUrl == null || sameChapterUrl(latestUrl, lastUrl)) return null;
    final n = WebFetcher.trailingNumber(latestUrl);
    final label = n != null ? 'Chương $n' : (latestTitle ?? '').trim();
    return 'Chưa đọc: ${label.isEmpty ? 'chương cuối' : label}';
  }

  // Lọc/tìm theo tên, không phân biệt hoa thường và dấu tiếng Việt.
  static bool matchesQuery(Map<String, dynamic> item, String query) {
    final q = query.trim();
    if (q.isEmpty) return true;
    return TocScreen.fold(title(item)).contains(TocScreen.fold(q));
  }

  static String title(Map<String, dynamic> item) =>
      (item['title'] as String?) ?? '';

  /// Nhãn thẻ "Đọc tiếp": tên truyện, không bao giờ là đường link.
  static String continueLabel({
    required String lastUrl,
    String? savedTitle,
    List<Map<String, dynamic>> library = const [],
  }) {
    final saved = savedTitle?.trim();
    if (saved != null && saved.isNotEmpty) return saved;
    if (lastUrl.startsWith('book:')) {
      final story = BookUrl.storyOf(lastUrl);
      final title = library
          .where((e) => e['story_url'] == story)
          .map((e) => e['title'] as String?)
          .firstOrNull;
      final n = BookUrl.chapterOf(lastUrl);
      final chapter = n == null ? '' : ' — Chương ${n + 1}';
      return title == null || title.trim().isEmpty
          ? 'Sách trong máy$chapter'
          : '${title.trim()}$chapter';
    }
    for (final e in library) {
      final title = (e['title'] as String?)?.trim();
      if (title == null || title.isEmpty) continue;
      final last = e['last_chapter_url'] as String?;
      final story = e['story_url'] as String?;
      if (sameChapterUrl(last, lastUrl) || sameChapterUrl(story, lastUrl)) {
        return title;
      }
    }
    return 'Chương vừa đọc';
  }

  /// Tên miền nguồn của truyện, để hai bản cùng tên ở hai trang không lẫn.
  /// Adapter đã cài (nếu có) là nguồn tin cậy — đúng cả khi link có subdomain.
  static String sourceLabel(String storyUrl, {String? adapterDomain}) {
    if (storyUrl.startsWith('book:')) return 'Sách trong máy';
    final d = adapterDomain?.trim();
    if (d != null && d.isNotEmpty) return d;
    return Uri.tryParse(storyUrl)?.host ?? '';
  }

  /// Truyện chưa đọc tới chương cuối đứng trước, trong nhóm đó mới đọc
  /// trước trước (updated_at DESC từ DB).
  static bool hasNew(Map<String, dynamic> item) =>
      newBadge(
        item['latest_chapter_url'] as String?,
        item['latest_chapter_title'] as String?,
        item['last_chapter_url'] as String?,
      ) !=
      null;

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  List<Map<String, dynamic>> _library = [];
  bool _loaded = false;
  bool _checking = false;
  String? _checkProgress;
  // Truyện đang được kiểm tra riêng từ nút trên thẻ (null khi không chạy).
  String? _checkingStory;
  // Thẻ "Đọc tiếp" ở đầu thư viện (thay tab Đọc cũ).
  String? _lastUrl;
  String? _lastTitle;
  // storyUrl → số chương trong mục lục đã lưu, để hiện "Chương x/y".
  Map<String, int> _tocCounts = {};
  // Sắp xếp: 'recent' (mới đọc — mặc định theo DB), 'newest' (có chương mới
  // lên đầu), 'title' (tên A–Z, không dấu). Tìm kiếm lọc theo tên.
  String _sort = 'recent';
  String _query = '';
  bool _hideAdult = false;
  Set<String> _adultDomains = {};
  // Hiện lại truyện 18+ chỉ trong phiên này; rời app là ẩn lại.
  bool _revealAdult = false;
  final TextEditingController _searchCtrl = TextEditingController();

  /// Danh sách hiện trên màn: lọc theo [_query] rồi sắp xếp theo [_sort].
  /// DB đã sort updated_at DESC nên 'recent' giữ nguyên thứ tự.
  List<Map<String, dynamic>> _display() {
    var items = _library;
    if (_query.trim().isNotEmpty) {
      items = items
          .where((i) => LibraryScreen.matchesQuery(i, _query))
          .toList();
    }
    switch (_sort) {
      case 'title':
        items = [...items]
          ..sort(
            (a, b) =>
                TocScreen.fold(LibraryScreen.title(a))
                    .compareTo(TocScreen.fold(LibraryScreen.title(b))),
          );
      case 'newest':
        items = [...items]
          ..sort((a, b) {
            final an = LibraryScreen.hasNew(a);
            final bn = LibraryScreen.hasNew(b);
            if (an != bn) return an ? -1 : 1;
            // Dart sort không stable: nhóm cùng trạng thái phải so rõ thứ tự.
            return (b['updated_at'] as int).compareTo(a['updated_at'] as int);
          });
    }
    return items;
  }

  Future<void> _setSort(String v) async {
    setState(() => _sort = v);
    await ref.read(appDbProvider).setSetting('librarySort', v);
  }

  @override
  void initState() {
    super.initState();
    _load();
    // Kiểm tra chương mới chạy ngầm lúc mở app xong cũng phải refresh list.
    LibraryChecker.revision.addListener(_onExternalCheck);
    LibraryChecker.progress.addListener(_onProgress);
    StoryDownloader.state.addListener(_onDownloadState);
  }

  @override
  void dispose() {
    LibraryChecker.revision.removeListener(_onExternalCheck);
    LibraryChecker.progress.removeListener(_onProgress);
    StoryDownloader.state.removeListener(_onDownloadState);
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _shownDownloadMessage;

  void _onDownloadState() {
    if (!mounted) return;
    setState(() {});
    final s = StoryDownloader.state.value;
    if (s != null && s.running) _shownDownloadMessage = null;
    if (s != null &&
        !s.running &&
        s.message != null &&
        s.message != _shownDownloadMessage) {
      _shownDownloadMessage = s.message;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(s.message!)));
    }
  }

  void _onProgress() {
    if (mounted) setState(() {});
  }

  void _onExternalCheck() {
    if (LibraryChecker.running) return;
    _load();
  }

  @override
  void didUpdateWidget(LibraryScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDbProvider);
    final lib = await db.getLibrary();
    // Đếm chương trong mục lục đã lưu cho từng truyện; truyện chưa có mục
    // lục (hoặc DB lỗi) thì bỏ qua, subtitle về dạng cũ.
    final counts = <String, int>{};
    for (final item in lib) {
      final url = item['story_url'] as String?;
      if (url == null) continue;
      try {
        final toc = await db.getToc(url);
        if (toc.isNotEmpty) counts[url] = toc.length;
      } catch (_) {}
    }
    final sort = await db.getSetting('librarySort') ?? 'recent';
    final lastUrl = await db.getSetting('lastUrl');
    final lastTitle = await db.getSetting('lastTitle');
    final hideAdult = await SourceRegistry.hideAdultEnabled(db);
    final adultDomains = await SourceRegistry.adultDomains(db);
    if (mounted) {
      setState(() {
        _library = lib;
        _tocCounts = counts;
        _sort = sort;
        _lastUrl = lastUrl;
        _lastTitle = lastTitle;
        _hideAdult = hideAdult;
        _adultDomains = adultDomains;
        _loaded = true;
      });
    }
  }

  bool _isAdultItem(Map<String, dynamic> item) => SourceRegistry.isAdultStory(
    item['story_url'] as String? ?? '',
    _adultDomains,
    ref.read(adapterRepoProvider),
  );

  bool _isAdultUrl(String url) => SourceRegistry.isAdultStory(
    storyUrlFromChapter(url),
    _adultDomains,
    ref.read(adapterRepoProvider),
  );

  void _open(Map<String, dynamic> item) {
    final url =
        (item['last_chapter_url'] as String?) ?? item['story_url'] as String;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          url: url,
          storyUrl: item['story_url'] as String,
          storyTitle: item['title'] as String?,
        ),
      ),
    ).then((_) => _load());
  }

  String _subtitle(Map<String, dynamic> item) {
    final last = item['last_chapter_url'] as String? ?? '';
    final total = _tocCounts[item['story_url']];
    final suffix = total == null ? '' : '/$total';
    if (last.startsWith('book:')) {
      final n = BookUrl.chapterOf(last);
      return n == null ? 'Sách trong máy' : 'Chương ${n + 1}$suffix';
    }
    // "Đang đọc: 87/1363" đủ nghĩa, bỏ chữ "Chương" cho đỡ chật ở cỡ chữ to.
    final n = WebFetcher.trailingNumber(last);
    return n != null
        ? 'Đang đọc: $n$suffix'
        : Uri.tryParse(last)?.pathSegments.lastOrNull ?? '';
  }

  Future<void> _checkNew() async {
    if (_checking) return;
    if (LibraryChecker.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang kiểm tra chương mới, chờ chút nhé')),
      );
      return;
    }
    final items = _library
        .where((i) => !(i['story_url'] as String).startsWith('book:'))
        .toList();
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Thư viện chỉ có sách trong máy')),
      );
      return;
    }
    setState(() => _checking = true);
    final res = await LibraryChecker.check(
      db: ref.read(appDbProvider),
      fetcher: ref.read(webFetcherProvider),
      repo: ref.read(adapterRepoProvider),
      items: items,
      onProgress: (progress) {
        if (mounted) setState(() => _checkProgress = progress);
      },
    );
    await _load();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkProgress = null;
    });
    if (res.ran && !res.cancelled) {
      await ref
          .read(appDbProvider)
          .setSetting(
            LibraryChecker.lastCheckKey,
            '${DateTime.now().millisecondsSinceEpoch}',
          );
    }
    if (!mounted || res.cancelled) return;
    final msg = res.fresh > 0
        ? '${res.fresh} truyện có chương mới'
        : 'Không có chương mới';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.warns.isEmpty ? msg : '$msg\n${res.warns.join('\n')}',
        ),
      ),
    );
  }

  /// Kiểm tra chương mới cho riêng một truyện từ nút trên thẻ. Không cập
  /// nhật mốc 6 giờ của lần kiểm tra cả thư viện — các truyện khác chưa quét.
  Future<void> _checkOne(Map<String, dynamic> item) async {
    final storyUrl = item['story_url'] as String? ?? '';
    if (storyUrl.startsWith('book:') || _checkingStory != null) return;
    if (LibraryChecker.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang kiểm tra chương mới, chờ chút nhé')),
      );
      return;
    }
    setState(() => _checkingStory = storyUrl);
    final db = ref.read(appDbProvider);
    try {
      final res = await LibraryChecker.check(
        db: db,
        fetcher: ref.read(webFetcherProvider),
        repo: ref.read(adapterRepoProvider),
        items: [item],
      );
      await _load();
      if (!mounted) return;
      if (!res.ran) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đang kiểm tra chương mới, chờ chút nhé'),
          ),
        );
        return;
      }
      if (res.warns.isNotEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(res.warns.join('\n'))));
        return;
      }
      final rows = await db.getLibrary();
      final row = rows
          .where((r) => sameChapterUrl(r['story_url'] as String?, storyUrl))
          .firstOrNull;
      if (row == null || !mounted) return;
      final badge = LibraryScreen.newBadge(
        row['latest_chapter_url'] as String?,
        row['latest_chapter_title'] as String?,
        row['last_chapter_url'] as String?,
      );
      if (badge == null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Không có chương mới')));
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            res.fresh > 0
                ? 'Có chương mới — $badge'
                : 'Còn chương chưa đọc — $badge',
          ),
          action: SnackBarAction(
            label: 'Đọc',
            onPressed: () => unawaited(_openNextUnread(row)),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Kiểm tra chương mới lỗi: ${friendlyError(e)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingStory = null);
    }
  }

  /// Mở chương chưa đọc kế tiếp — chương ngay sau vị trí đang đọc, không nhảy
  /// thẳng chương mới nhất để đọc lần lượt các chương mới.
  Future<void> _openNextUnread(Map<String, dynamic> row) async {
    final storyUrl = row['story_url'] as String? ?? '';
    final last = row['last_chapter_url'] as String? ?? storyUrl;
    List<ChapterRef> toc;
    try {
      toc = await ref.read(appDbProvider).getToc(storyUrl);
    } catch (_) {
      toc = const [];
    }
    final url = ReaderScreen.nextChapterAfter(last, toc)?.url ?? last;
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          url: url,
          storyUrl: storyUrl,
          storyTitle: row['title'] as String?,
        ),
      ),
    );
    if (mounted) _load();
  }

  /// Chạm giữ thẻ: menu thao tác — xóa không còn là chạm giữ trực tiếp nên
  /// không xóa nhầm.
  Future<void> _showItemMenu(Map<String, dynamic> item) async {
    final isBook = (item['story_url'] as String? ?? '').startsWith('book:');
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('Đọc tiếp'),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
            if (!isBook)
              ListTile(
                leading: const Icon(Icons.headphones),
                title: const Text('Nghe từ chương đang đọc'),
                onTap: () => Navigator.pop(ctx, 'listen'),
              ),
            if (!isBook)
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Tải cả truyện'),
                onTap: () => Navigator.pop(ctx, 'download'),
              ),
            if (!isBook)
              ListTile(
                leading: const Icon(Icons.delete_sweep_outlined),
                title: const Text('Xoá chương đã tải'),
                onTap: () => Navigator.pop(ctx, 'clearCache'),
              ),
            if (!isBook)
              ListTile(
                leading: const Icon(Icons.new_releases_outlined),
                title: const Text('Kiểm tra chương mới'),
                onTap: () => Navigator.pop(ctx, 'check'),
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Xóa khỏi thư viện'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'open':
        _open(item);
      case 'listen':
        unawaited(_listen(item));
      case 'download':
        unawaited(_downloadAll(item));
      case 'clearCache':
        unawaited(_clearCached(item));
      case 'check':
        unawaited(_checkOne(item));
      case 'delete':
        _remove(item);
    }
  }

  /// Nghe ngay từ thẻ thư viện, không phải mở màn đọc: mini-player hiện lên
  /// trên thanh tab, chương kế vẫn tự sang như chế độ nghe trong màn đọc.
  Future<void> _listen(Map<String, dynamic> item) async {
    final storyUrl = item['story_url'] as String? ?? '';
    if (storyUrl.isEmpty || storyUrl.startsWith('book:')) return;
    final chapterUrl = (item['last_chapter_url'] as String?) ?? storyUrl;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Đang tải chương để nghe…')));
    final ok = await ref
        .read(ttsPlayerProvider)
        .playChapter(
          chapterUrl,
          storyUrl: storyUrl,
          storyTitle: item['title'] as String?,
        );
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Không tải được chương để nghe. Mở truyện bằng tay để xem chi tiết.',
        ),
      ),
    );
  }

  Future<void> _downloadAll(Map<String, dynamic> item) async {
    final storyUrl = item['story_url'] as String? ?? '';
    if (storyUrl.isEmpty || storyUrl.startsWith('book:')) return;
    if (StoryDownloader.running) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang tải một truyện khác, chờ xong đã')),
      );
      return;
    }
    final ok = await StoryDownloader.start(
      db: ref.read(appDbProvider),
      fetcher: ref.read(webFetcherProvider),
      adapters: ref.read(adapterRepoProvider),
      storyUrl: storyUrl,
    );
    if (!mounted) return;
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đang tải cả truyện. Tiến độ hiện ở đầu thư viện.'),
        ),
      );
      return;
    }
    final msg = StoryDownloader.state.value?.message;
    if (msg != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _clearCached(Map<String, dynamic> item) async {
    final storyUrl = item['story_url'] as String? ?? '';
    if (storyUrl.isEmpty || storyUrl.startsWith('book:')) return;
    final dl = StoryDownloader.state.value;
    if (dl != null && dl.running && dl.storyUrl == storyUrl) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang tải truyện này, dừng tải trước đã')),
      );
      return;
    }
    final db = ref.read(appDbProvider);
    final count = await db.cachedChapterCountForStory(storyUrl);
    if (!mounted) return;
    if (count == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Truyện này chưa có chương nào tải sẵn')),
      );
      return;
    }
    final title = (item['title'] as String? ?? '').trim();
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá chương đã tải?'),
        content: Text(
          'Xoá $count chương đã tải của "${title.isEmpty ? 'truyện này' : title}". '
          'Đọc lại sẽ tải từ web như bình thường.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final deleted = await db.clearCachedChaptersForStory(storyUrl);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Đã xoá $deleted chương đã tải')));
    await _load();
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá khỏi thư viện?'),
        content: Text(item['title'] as String? ?? ''),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok == true) {
      final storyUrl = item['story_url'] as String;
      final dl = StoryDownloader.state.value;
      if (dl != null && dl.running && dl.storyUrl == storyUrl) {
        StoryDownloader.cancel();
      }
      await ref.read(appDbProvider).removeFromLibrary(storyUrl);
      final cover = item['cover_url'] as String?;
      if (cover != null && !cover.startsWith('http')) {
        try {
          final f = File(cover);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await _load();
    }
  }

  static const _sortLabels = {
    'recent': 'Mới đọc trước',
    'newest': 'Chưa đọc hết lên đầu',
    'title': 'Tên A–Z',
  };

  @override
  Widget build(BuildContext context) {
    final all = _display();
    final adultCount = _hideAdult ? all.where(_isAdultItem).length : 0;
    final hideNow = _hideAdult && !_revealAdult;
    final items = hideNow ? all.where((i) => !_isAdultItem(i)).toList() : all;
    final hidden = hideNow
        ? all.where(_isAdultItem).toList()
        : const <Map<String, dynamic>>[];
    final lastHidden =
        hideNow && (_lastUrl?.isNotEmpty ?? false) && _isAdultUrl(_lastUrl!);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Thư viện'),
        actions: [
          IconButton(
            icon: _checking
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.new_releases_outlined),
            tooltip: 'Check chương mới',
            onPressed: _checking ? null : _checkNew,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sắp xếp',
            onSelected: _setSort,
            itemBuilder: (_) => [
              for (final e in _sortLabels.entries)
                PopupMenuItem(
                  value: e.key,
                  child: Row(
                    children: [
                      Icon(
                        _sort == e.key
                            ? Icons.check_box
                            : Icons.check_box_outline_blank,
                        size: 18,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(e.value)),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (StoryDownloader.state.value case final dl? when dl.running)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      dl.title.isEmpty
                          ? 'Đang tải cả truyện: ${dl.done}/${dl.total}'
                          : 'Đang tải ${dl.title}: ${dl.done}/${dl.total}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: StoryDownloader.cancel,
                    child: const Text('Dừng'),
                  ),
                ],
              ),
            ),
          if (_checking || LibraryChecker.running)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Đang kiểm tra ${_checkProgress ?? LibraryChecker.progress.value ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: LibraryChecker.cancel,
                    child: const Text('Dừng'),
                  ),
                ],
              ),
            ),
          if (_loaded && (_lastUrl?.isNotEmpty ?? false) && !lastHidden)
            _continueCard(),
          if (_loaded) _addButtons(),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : _library.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.local_library_outlined,
                            size: 64,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Chưa có truyện trong thư viện',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Bấm Dán link hoặc Nhập file ở trên. '
                            'Tìm ở tab Tìm kiếm thì phải bấm Lưu — '
                            'tìm thôi chưa thêm vào đây.',
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                : Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: TextField(
                          controller: _searchCtrl,
                          onChanged: (v) => setState(() => _query = v),
                          decoration: InputDecoration(
                            isDense: true,
                            prefixIcon: const Icon(Icons.search, size: 20),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 36,
                              minHeight: 36,
                            ),
                            hintText: 'Tìm truyện trong thư viện',
                            suffixIcon: _query.isEmpty
                                ? null
                                : IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    tooltip: 'Xóa tìm kiếm',
                                    onPressed: () {
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                    },
                                  ),
                          ),
                        ),
                      ),
                      Expanded(
                        child: items.isEmpty && _query.trim().isNotEmpty
                            ? Center(
                                child: Text(
                                  'Không có truyện khớp "${_query.trim()}"',
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.all(16),
                                children: [
                                  for (final item in items) _card(item),
                                  if (hidden.isNotEmpty ||
                                      (_hideAdult && adultCount > 0))
                                    Card(
                                      child: ListTile(
                                        leading: Icon(
                                          _revealAdult
                                              ? Icons.visibility_outlined
                                              : Icons.visibility_off_outlined,
                                        ),
                                        title: Text(
                                          _revealAdult
                                              ? 'Đang hiện $adultCount truyện 18+'
                                              : 'Đã ẩn $adultCount truyện 18+',
                                        ),
                                        trailing: TextButton(
                                          onPressed: () => setState(
                                            () => _revealAdult = !_revealAdult,
                                          ),
                                          child: Text(
                                            _revealAdult ? 'Ẩn lại' : 'Hiện',
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  /// Thẻ "Đọc tiếp" ở đầu thư viện — trước đây là tab Đọc riêng.
  Widget _continueCard() {
    final url = _lastUrl!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Card(
        child: ListTile(
          leading: const Icon(Icons.history),
          title: Text(
            LibraryScreen.continueLabel(
              lastUrl: url,
              savedTitle: _lastTitle,
              library: _library,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.arrow_forward),
          onTap: () => openWebLink(context, url).then((_) {
            if (mounted) _load();
          }),
        ),
      ),
    );
  }

  Widget _addButtons() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () =>
                  showPasteLinkDialog(context).then((_) => _load()),
              icon: const Icon(Icons.link),
              label: const Text('Dán link'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => pickAndImportBook(
                context,
                ref.read(appDbProvider),
              ).then((_) => _load()),
              icon: const Icon(Icons.file_open_outlined),
              label: const Text('Nhập file'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(Map<String, dynamic> item) {
    final badge = LibraryScreen.newBadge(
      item['latest_chapter_url'] as String?,
      item['latest_chapter_title'] as String?,
      item['last_chapter_url'] as String?,
    );
    final storyUrl = item['story_url'] as String? ?? '';
    final isBook = storyUrl.startsWith('book:');
    final total = _tocCounts[storyUrl];
    final source = LibraryScreen.sourceLabel(
      storyUrl,
      adapterDomain: ref.read(adapterRepoProvider).forUrl(storyUrl)?.domain,
    );
    final small = Theme.of(context).textTheme.bodySmall;
    final checkingThis = _checkingStory == storyUrl;
    final checkBusy =
        _checking || LibraryChecker.running || _checkingStory != null;
    final primary = Theme.of(context).colorScheme.primary;
    // Thẻ tự dựng thay vì ListTile: hai nút xếp dọc trong trailing của ListTile
    // bị giới hạn chiều cao và tràn ở cỡ chữ lớn.
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(item),
        onLongPress: () => _showItemMenu(item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 48,
                child: CoverImage(url: item['cover_url'] as String?),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item['title'] as String? ?? '',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 2),
                    // Máy để chữ to thì dòng "Đang đọc: 12/345" cần xuống
                    // dòng, cắt một dòng là mất đúng số chương cần thấy.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Có tổng số chương rồi thì "87/1363" đã nói chưa
                        // đọc hết; chấm nhỏ giữ tín hiệu, không lặp cả dòng.
                        if (badge != null && total != null)
                          Semantics(
                            label: 'Còn chương chưa đọc',
                            child: Padding(
                              padding: const EdgeInsets.only(top: 5, right: 6),
                              child: Icon(
                                Icons.circle,
                                key: ValueKey('new-dot-$storyUrl'),
                                size: 8,
                                color: primary,
                              ),
                            ),
                          ),
                        Expanded(
                          child: Text(
                            _subtitle(item),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: small,
                          ),
                        ),
                      ],
                    ),
                    if (source.isNotEmpty)
                      Text(
                        source,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: small?.copyWith(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    // Chưa lưu được mục lục (không có tổng) thì dòng này là
                    // thông tin duy nhất báo còn chương chưa đọc.
                    if (badge != null && total == null)
                      Text(
                        badge,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: primary,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.delete_outline),
                    tooltip: 'Xóa khỏi thư viện',
                    onPressed: () => _remove(item),
                  ),
                  if (!isBook)
                    IconButton(
                      key: ValueKey('check-new-$storyUrl'),
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Kiểm tra chương mới',
                      icon: checkingThis
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.new_releases_outlined),
                      onPressed: checkBusy ? null : () => _checkOne(item),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
