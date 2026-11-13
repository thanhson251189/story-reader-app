import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cover_image.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import '../reader/reader_screen.dart';

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

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  List<Map<String, dynamic>> _library = [];
  bool _loaded = false;
  bool _checking = false;
  String? _checkProgress;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(LibraryScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) _load();
  }

  Future<void> _load() async {
    final lib = await ref.read(appDbProvider).getLibrary();
    if (mounted) {
      setState(() {
        _library = lib;
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
    if (last.startsWith('book:')) {
      final n = int.tryParse(last.split(':').last);
      return n == null ? 'Sách trong máy' : 'Chương ${n + 1}';
    }
    final n = WebFetcher.trailingNumber(last);
    return n != null
        ? 'Đang đọc: Chương $n'
        : Uri.tryParse(last)?.pathSegments.lastOrNull ?? '';
  }

  Future<void> _checkNew() async {
    if (_checking) return;
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
    final db = ref.read(appDbProvider);
    final fetcher = ref.read(webFetcherProvider);
    final repo = ref.read(adapterRepoProvider);
    var fresh = 0;
    final warns = <String>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final storyUrl = item['story_url'] as String;
      final title = item['title'] as String? ?? storyUrl;
      if (mounted) {
        setState(() => _checkProgress = '${i + 1}/${items.length}: $title');
      }
      final adapter = repo.forUrl(storyUrl);
      if (adapter == null) {
        warns.add('$title: chưa có adapter');
        continue;
      }
      try {
        final info = await fetcher.fetchStory(storyUrl, adapter);
        if (info.chapters.isEmpty) {
          warns.add('$title: không lấy được mục lục');
          continue;
        }
        final last = info.chapters.last;
        await db.setLatestChapter(storyUrl, last.url, last.title);
        await db.saveToc(storyUrl, info.chapters);
        if (last.url != (item['last_chapter_url'] as String? ?? '')) fresh++;
      } catch (e) {
        warns.add('$title: ${e.toString().replaceFirst('Exception: ', '')}');
      }
    }
    await _load();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkProgress = null;
    });
    final msg = fresh > 0
        ? '$fresh truyện có chương mới'
        : 'Không có chương mới';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(warns.isEmpty ? msg : '$msg\n${warns.join('\n')}'),
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

  @override
  Widget build(BuildContext context) {
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
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      for (final item in _library) _card(item),
                      const SizedBox(height: 8),
                      Center(
                        child: Text(
                          'Giữ một truyện để xoá khỏi thư viện',
                          style: Theme.of(context).textTheme.bodySmall,
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
