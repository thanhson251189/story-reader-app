import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/cover_image.dart';
import '../core/errors.dart';
import '../core/providers.dart';
import '../data/backup.dart';
import '../fetcher/web_fetcher.dart';
import '../reader/reader_screen.dart';
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
  bool _busy = false;
  bool _autoCheck = true;
  String? _checkProgress;
  // storyUrl → số chương trong mục lục đã lưu, để hiện "Chương x/y".
  Map<String, int> _tocCounts = {};

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
    final auto = (await db.getSetting('autoCheckNew') ?? '1') == '1';
    if (mounted) {
      setState(() {
        _library = lib;
        _tocCounts = counts;
        _autoCheck = auto;
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
      final n = int.tryParse(last.split(':').last);
      return n == null ? 'Sách trong máy' : 'Chương ${n + 1}$suffix';
    }
    final n = WebFetcher.trailingNumber(last);
    return n != null
        ? 'Đang đọc: Chương $n$suffix'
        : Uri.tryParse(last)?.pathSegments.lastOrNull ?? '';
  }

  Future<void> _checkNew() async {
    if (_checking || _busy) return;
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

  Future<void> _toggleAutoCheck() async {
    final v = !_autoCheck;
    await ref.read(appDbProvider).setSetting('autoCheckNew', v ? '1' : '0');
    if (mounted) setState(() => _autoCheck = v);
  }

  Future<void> _backup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dirPath = await FilePicker.getDirectoryPath();
      if (!mounted) return;
      if (dirPath == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Đang đóng gói dữ liệu...')));
      final data = await DataBackup(ref.read(appDbProvider)).export();
      final stamp = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name =
          'story_reader_backup_${stamp.year}${two(stamp.month)}${two(stamp.day)}'
          '_${two(stamp.hour)}${two(stamp.minute)}.json';
      await File(p.join(dirPath, name)).writeAsString(jsonEncode(data));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã lưu "$name" — gồm thư viện, vị trí đọc và sách đã nhập.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sao lưu lỗi: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Phục hồi từ file sao lưu?'),
        content: const Text(
          'Dữ liệu trong file sẽ được ghép vào dữ liệu hiện có, không xoá gì. '
          'Truyện, vị trí đọc và sách đã nhập sẽ trở lại như lúc sao lưu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Phục hồi'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      final path = picked?.path;
      if (!mounted) return;
      if (path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang khôi phục dữ liệu...')),
      );
      final db = ref.read(appDbProvider);
      final data =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      await DataBackup(db).import(data);
      // Bản nguồn truyện đã cài nằm trong settings khôi phục; nạp luôn để
      // không phải mở lại app.
      await SourceRegistry.restoreInstalled(
        db,
        ref.read(adapterRepoProvider),
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Đã khôi phục xong.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Phục hồi lỗi: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
            onPressed: _checking || _busy ? null : _checkNew,
          ),
          PopupMenuButton<String>(
            tooltip: 'Tuỳ chọn thư viện',
            onSelected: (v) {
              if (v == 'backup') _backup();
              if (v == 'restore') _restore();
              if (v == 'auto') _toggleAutoCheck();
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'auto',
                child: Row(
                  children: [
                    Icon(
                      _autoCheck
                          ? Icons.check_box
                          : Icons.check_box_outline_blank,
                      size: 18,
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text('Tự kiểm tra chương mới khi mở app'),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'backup',
                child: Row(
                  children: [
                    Icon(Icons.save_outlined, size: 18),
                    SizedBox(width: 12),
                    Expanded(child: Text('Sao lưu dữ liệu')),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'restore',
                child: Row(
                  children: [
                    Icon(Icons.restore_outlined, size: 18),
                    SizedBox(width: 12),
                    Expanded(child: Text('Phục hồi từ file sao lưu')),
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
