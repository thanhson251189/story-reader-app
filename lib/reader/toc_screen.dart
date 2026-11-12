import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
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

  @override
  ConsumerState<TocScreen> createState() => _TocScreenState();
}

class _TocScreenState extends ConsumerState<TocScreen> {
  List<ChapterRef> _chapters = [];
  Set<String> _cached = {};
  bool _loading = true;
  String? _error;
  String? _title;
  bool _downloading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDbProvider);
    var chapters = await db.getToc(widget.storyUrl);
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
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _downloadAhead() async {
    if (_downloading || _chapters.isEmpty) return;
    setState(() => _downloading = true);
    final db = ref.read(appDbProvider);
    final fetcher = ref.read(webFetcherProvider);
    var start = 0;
    if (widget.currentChapterUrl != null) {
      final i = _chapters.indexWhere((c) => c.url == widget.currentChapterUrl);
      if (i >= 0) start = i;
    }
    var ok = 0;
    for (var i = start; i < _chapters.length && ok < 5; i++) {
      final url = _chapters[i].url;
      if (await db.getCachedChapter(url) != null) {
        if (mounted) setState(() => _cached.add(url));
        continue;
      }
      final adapter = ref.read(adapterRepoProvider).forUrl(url);
      if (adapter == null) break;
      try {
        final c = await fetcher.fetchChapter(url, adapter);
        await db.cacheChapter(c);
        ok++;
        if (mounted) setState(() => _cached.add(url));
      } catch (_) {
        break;
      }
    }
    if (!mounted) return;
    setState(() => _downloading = false);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Đã tải trước $ok chương')));
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
          if (!widget.storyUrl.startsWith('book:'))
            IconButton(
              icon: _downloading
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              tooltip: 'Tải trước 5 chương',
              onPressed: _downloading ? null : _downloadAhead,
            ),
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
          : ListView.builder(
              itemCount: _chapters.length,
              itemBuilder: (_, i) {
                final c = _chapters[i];
                final isCurrent = c.url == widget.currentChapterUrl;
                return ListTile(
                  dense: true,
                  title: Text(
                    c.title.isEmpty ? 'Chương ${i + 1}' : c.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: isCurrent
                        ? TextStyle(
                            color: Theme.of(context).colorScheme.primary,
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
                      builder: (_) =>
                          ReaderScreen(url: c.url, storyUrl: widget.storyUrl),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
