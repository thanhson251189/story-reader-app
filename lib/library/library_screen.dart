import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cover_image.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import '../reader/reader_screen.dart';
import '../reader/toc_screen.dart';
import 'library_checker.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  final bool active;
  const LibraryScreen({super.key, required this.active});

  static String? newBadge(
    String? latestUrl,
    String? latestTitle,
    String? lastUrl,
  ) {
    if (latestUrl == null || latestUrl == lastUrl) return null;
    final n = WebFetcher.trailingNumber(latestUrl);
    final label = n != null ? 'Chương $n' : (latestTitle ?? '').trim();
    return 'Mới: ${label.isEmpty ? 'chương mới' : label}';
  }

  // Lọc/tìm theo tên, không phân biệt hoa thường và dấu tiếng Việt.
  static bool matchesQuery(Map<String, dynamic> item, String query) {
    final q = query.trim();
    if (q.isEmpty) return true;
    return TocScreen.fold(title(item)).contains(TocScreen.fold(q));
  }

  static String title(Map<String, dynamic> item) =>
      (item['title'] as String?) ?? '';

  /// Truyện có chương mới (badge "Mới") đứng trước, trong nhóm đó mới đọc
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
  // storyUrl → số chương trong mục lục đã lưu, để hiện "Chương x/y".
  Map<String, int> _tocCounts = {};
  // Sắp xếp: 'recent' (mới đọc — mặc định theo DB), 'newest' (có chương mới
  // lên đầu), 'title' (tên A–Z, không dấu). Tìm kiếm lọc theo tên.
  String _sort = 'recent';
  String _query = '';
  final TextEditingController _searchCtrl = TextEditingController();

  /// Danh sách hiện trên màn: lọc theo [_query] rồi sắp xếp theo [_sort].
  /// DB đã sort updated_at DESC nên 'recent' giữ nguyên thứ tự.
  List<Map<String, dynamic>> _display() {
    var items = _library;
    if (_query.trim().isNotEmpty) {
      items = items.where((i) => LibraryScreen.matchesQuery(i, _query)).toList();
    }
    switch (_sort) {
      case 'title':
        items = [...items]..sort(
          (a, b) => TocScreen.fold(
            LibraryScreen.title(a),
          ).compareTo(TocScreen.fold(LibraryScreen.title(b))),
        );
      case 'newest':
        items = [...items]..sort((a, b) {
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
  }

  @override
  void dispose() {
    LibraryChecker.revision.removeListener(_onExternalCheck);
    _searchCtrl.dispose();
    super.dispose();
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
    if (mounted) {
      setState(() {
        _library = lib;
        _tocCounts = counts;
        _sort = sort;
        _loaded = true;
      });
    }
  }

  void _open(Map<String, dynamic> item) {
    final url =
        (item['last_chapter_url'] as String?) ?? item['story_url'] as String;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ReaderScreen(url: url, storyUrl: item['story_url'] as String),
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
    final n = WebFetcher.trailingNumber(last);
    return n != null
        ? 'Đang đọc: Chương $n$suffix'
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
      await ref
          .read(appDbProvider)
          .removeFromLibrary(item['story_url'] as String);
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
    'newest': 'Chương mới lên đầu',
    'title': 'Tên A–Z',
  };

  @override
  Widget build(BuildContext context) {
    final items = _display();
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
          if (_checking)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                      'Đang check ${_checkProgress ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
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
                            'Mở truyện rồi bấm nút đánh dấu ở màn đọc, '
                            'hoặc tìm truyện ở tab Tìm kiếm để thêm vào đây.',
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
                        child: items.isEmpty
                            ? Center(
                                child: Text(
                                  'Không có truyện khớp "${_query.trim()}"',
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.all(16),
                                children: [
                                  for (final item in items) _card(item),
                                  const SizedBox(height: 8),
                                  Center(
                                    child: Text(
                                      'Giữ một truyện để xoá khỏi thư viện',
                                      style:
                                          Theme.of(context).textTheme.bodySmall,
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

  Widget _card(Map<String, dynamic> item) {
    final badge = LibraryScreen.newBadge(
      item['latest_chapter_url'] as String?,
      item['latest_chapter_title'] as String?,
      item['last_chapter_url'] as String?,
    );
    return Card(
      child: ListTile(
        leading: CoverImage(url: item['cover_url'] as String?),
        title: Text(
          item['title'] as String? ?? '',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_subtitle(item), maxLines: 1, overflow: TextOverflow.ellipsis),
            if (badge != null)
              Text(
                badge,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
          ],
        ),
        trailing: const Icon(Icons.arrow_forward),
        onTap: () => _open(item),
        onLongPress: () => _remove(item),
      ),
    );
  }
}
