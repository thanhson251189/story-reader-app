import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../sources/sources_screen.dart';
import 'open_actions.dart';

class ReadTab extends ConsumerStatefulWidget {
  final bool active;
  const ReadTab({super.key, required this.active});

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

  @override
  ConsumerState<ReadTab> createState() => _ReadTabState();
}

class _ReadTabState extends ConsumerState<ReadTab> {
  String? _lastUrl;
  String? _lastTitle;
  List<Map<String, dynamic>> _library = [];

  @override
  void initState() {
    super.initState();
    _loadLast();
  }

  @override
  void didUpdateWidget(ReadTab old) {
    super.didUpdateWidget(old);
    // Tab nằm trong IndexedStack nên initState chỉ chạy lúc mở app: quay lại
    // tab Đọc sau khi đọc truyện khác (từ Thư viện/Tìm kiếm) phải nạp lại
    // "Đọc tiếp", không thì thẻ này cứ giữ link truyện cũ lúc mở app.
    if (widget.active && !old.active) _loadLast();
  }

  Future<void> _loadLast() async {
    final db = ref.read(appDbProvider);
    final last = await db.getSetting('lastUrl');
    final title = await db.getSetting('lastTitle');
    final lib = await db.getLibrary();
    if (mounted) {
      setState(() {
        _lastUrl = last;
        _lastTitle = title;
        _library = lib;
      });
    }
  }

  void _open(String url) {
    openWebLink(context, url).then((_) {
      if (mounted) _loadLast();
    });
  }

  String _lastLabel() => ReadTab.continueLabel(
    lastUrl: _lastUrl!,
    savedTitle: _lastTitle,
    library: _library,
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Story Reader'),
        actions: [
          IconButton(
            tooltip: 'Nguồn truyện',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SourcesScreen()),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_lastUrl != null) ...[
            Text('Đọc tiếp', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.history),
                title: Text(
                  _lastLabel(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => _open(_lastUrl!),
              ),
            ),
          ] else
            Text(
              'Chưa đọc truyện nào. Vào Thư viện để dán link hoặc nhập file.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
        ],
      ),
    );
  }
}
