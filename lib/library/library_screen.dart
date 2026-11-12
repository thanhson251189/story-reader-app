import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/cover_image.dart';
import '../core/providers.dart';
import '../reader/reader_screen.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  final bool active;
  const LibraryScreen({super.key, required this.active});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  List<Map<String, dynamic>> _library = [];
  bool _loaded = false;

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
      MaterialPageRoute(builder: (_) => ReaderScreen(url: url)),
    ).then((_) => _load());
  }

  String _subtitle(Map<String, dynamic> item) {
    final last = item['last_chapter_url'] as String? ?? '';
    if (last.startsWith('book:')) {
      final n = int.tryParse(last.split(':').last);
      return n == null ? 'Sách trong máy' : 'Chương ${n + 1}';
    }
    return Uri.tryParse(last)?.pathSegments.lastOrNull ?? '';
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
      appBar: AppBar(title: const Text('Thư viện')),
      body: !_loaded
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
                for (final item in _library)
                  Card(
                    child: ListTile(
                      leading: CoverImage(url: item['cover_url'] as String?),
                      title: Text(
                        item['title'] as String? ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(_subtitle(item), maxLines: 1),
                      trailing: const Icon(Icons.arrow_forward),
                      onTap: () => _open(item),
                      onLongPress: () => _remove(item),
                    ),
                  ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Giữ một truyện để xoá khỏi thư viện',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
    );
  }
}
