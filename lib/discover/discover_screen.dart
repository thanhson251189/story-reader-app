import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import '../reader/reader_screen.dart';
import '../sources/registry.dart';
import '../sources/sources_screen.dart';
import 'discover_opener.dart';

/// Tab Khám phá: mở trang chủ của từng nguồn ngay trong app, để người chưa
/// biết đọc gì vẫn xem được danh sách truyện như trên web. Bấm "Mở bằng app"
/// thì nhận diện trang truyện/chương rồi đọc hoặc lưu vào thư viện.
class DiscoverScreen extends ConsumerStatefulWidget {
  final bool active;
  const DiscoverScreen({super.key, required this.active});

  static String homeUrl(SourceAdapter a) => 'https://${a.domain}/';

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  InAppWebViewController? _web;
  String? _preferred;
  Map<String, String> _names = {};
  String? _url;
  bool _canBack = false;
  bool _canForward = false;
  bool _pageLoading = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _loadPreferred();
  }

  Future<void> _loadPreferred() async {
    try {
      final db = ref.read(appDbProvider);
      final saved = await db.getSetting('discoverSource');
      final names = SourceRegistry.namesFromCache(
        await db.getSetting('registryIndexCache'),
        await SourceRegistry(
          db,
          ref.read(adapterRepoProvider),
        ).nameOverrides(),
      );
      if (mounted) {
        setState(() {
          _preferred = saved;
          _names = names;
        });
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(DiscoverScreen old) {
    super.didUpdateWidget(old);
    // Tab nằm trong IndexedStack: cài thêm nguồn ở màn khác rồi quay lại phải
    // thấy nguồn mới trong danh sách chọn.
    if (widget.active && !old.active) setState(() {});
  }

  List<SourceAdapter> get _sources => [...ref.read(adapterRepoProvider).all]
    ..sort((a, b) => a.domain.compareTo(b.domain));

  String? _effectiveDomain(List<SourceAdapter> sources) {
    if (sources.isEmpty) return null;
    final p = _preferred;
    if (p != null && sources.any((a) => a.domain == p)) return p;
    return sources.first.domain;
  }

  void _select(String domain) {
    if (domain == _effectiveDomain(_sources)) return;
    setState(() {
      _preferred = domain;
      _web = null;
      _url = null;
      _canBack = false;
      _canForward = false;
      _pageLoading = true;
    });
    unawaited(ref.read(appDbProvider).setSetting('discoverSource', domain));
  }

  Future<void> _updateNav(InAppWebViewController c) async {
    try {
      final canBack = await c.canGoBack();
      final canForward = await c.canGoForward();
      final url = (await c.getUrl())?.toString();
      if (mounted) {
        setState(() {
          _canBack = canBack;
          _canForward = canForward;
          _url = url;
        });
      }
    } catch (_) {}
  }

  Future<void> _openInApp() async {
    final web = _web;
    if (web == null || _opening) return;
    final current = (await web.getUrl())?.toString();
    if (current == null || current.isEmpty) return;
    setState(() => _opening = true);
    try {
      final page = await DiscoverOpener(
        fetcher: ref.read(webFetcherProvider),
        repo: ref.read(adapterRepoProvider),
      ).open(current);
      if (!mounted) return;
      if (page.chapter != null) {
        final c = page.chapter!;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ReaderScreen(url: c.url.isEmpty ? current : c.url),
          ),
        );
        return;
      }
      if (page.story != null) {
        await _showStorySheet(page);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(page.error ?? 'Không mở được trang này')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không mở được bằng app: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  String _titleOf(NovelInfo info) {
    final t = info.title.trim();
    return t.isEmpty ? 'Truyện đã lưu' : t;
  }

  Future<void> _showStorySheet(DiscoverPage page) async {
    final info = page.story!;
    final title = _titleOf(info);
    List<Map<String, dynamic>> lib;
    try {
      lib = await ref.read(appDbProvider).getLibrary();
    } catch (_) {
      lib = const [];
    }
    final row = lib
        .where((r) => sameChapterUrl(r['story_url'] as String?, page.url))
        .firstOrNull;
    final savedLast = row?['last_chapter_url'] as String?;
    final inLib = row != null;
    if (!mounted) return;
    final host = Uri.tryParse(page.url)?.host ?? '';
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${info.chapters.length} chương · $host'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: Text(inLib ? 'Đọc tiếp' : 'Đọc chương đầu'),
              onTap: () => Navigator.pop(ctx, 'read'),
            ),
            if (!inLib)
              ListTile(
                leading: const Icon(Icons.bookmark_add_outlined),
                title: const Text('Thêm vào thư viện'),
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'read') {
      final start =
          savedLast ??
          (info.chapters.isEmpty ? page.url : info.chapters.first.url);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReaderScreen(
            url: start,
            storyUrl: page.url,
            storyTitle: title,
          ),
        ),
      );
    } else if (action == 'save') {
      await _saveStory(page, title);
    }
  }

  Future<void> _saveStory(DiscoverPage page, String title) async {
    final info = page.story!;
    final db = ref.read(appDbProvider);
    // Tên trống thì lấy tên tạm để thẻ thư viện không bị trống.
    final toSave = info.title.trim().isEmpty
        ? NovelInfo(
            title: title,
            coverUrl: info.coverUrl,
            chapters: info.chapters,
            tocComplete: info.tocComplete,
          )
        : info;
    try {
      await db.saveStoryInfo(
        page.url,
        toSave,
        lastChapterUrl: info.chapters.first.url,
      );
      final last = info.chapters.last;
      await db.setLatestChapter(page.url, last.url, last.title);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã thêm "$title" (${info.chapters.length} chương) vào thư viện',
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Không lưu được: ${friendlyError(e)}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    final domain = _effectiveDomain(sources);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Khám phá'),
        actions: [
          IconButton(
            tooltip: 'Nguồn truyện',
            icon: const Icon(Icons.dns_outlined),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SourcesScreen()),
              );
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: sources.isEmpty
          ? _empty()
          : Column(
              children: [
                _sourceChips(sources, domain!),
                _toolbar(),
                Expanded(
                  child: InAppWebView(
                    key: ValueKey(domain),
                    initialUrlRequest: URLRequest(
                      url: WebUri(
                        DiscoverScreen.homeUrl(
                          sources.firstWhere((a) => a.domain == domain),
                        ),
                      ),
                    ),
                    initialSettings: WebFetcher.settings,
                    onWebViewCreated: (c) {
                      _web = c;
                      _updateNav(c);
                    },
                    onLoadStart: (_, _) {
                      if (mounted) setState(() => _pageLoading = true);
                    },
                    onLoadStop: (c, _) {
                      if (mounted) setState(() => _pageLoading = false);
                      _updateNav(c);
                    },
                    // Trang lỗi/mất mạng không có onLoadStop: mở lại nút
                    // "Mở bằng app" thay vì treo spinner mãi.
                    onReceivedError: (_, _, _) {
                      if (mounted) setState(() => _pageLoading = false);
                    },
                    onReceivedHttpError: (_, _, _) {
                      if (mounted) setState(() => _pageLoading = false);
                    },
                    onUpdateVisitedHistory: (c, _, _) => _updateNav(c),
                  ),
                ),
              ],
            ),
      floatingActionButton: sources.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _opening || _pageLoading ? null : _openInApp,
              icon: _opening
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_stories),
              label: Text(_opening ? 'Đang đọc trang...' : 'Mở bằng app'),
            ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.explore_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              'Chưa cài nguồn truyện',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Vào Nguồn truyện để thêm nguồn, rồi quay lại đây để xem trang '
              'của nguồn ngay trong app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SourcesScreen()),
                );
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.dns_outlined),
              label: const Text('Mở Nguồn truyện'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceChips(List<SourceAdapter> sources, String domain) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final a in sources)
            Padding(
              padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
              child: ChoiceChip(
                label: Text(SourceRegistry.labelFor(a.domain, _names)),
                selected: a.domain == domain,
                onSelected: (_) => _select(a.domain),
              ),
            ),
        ],
      ),
    );
  }

  Widget _toolbar() {
    return Row(
      children: [
        IconButton(
          tooltip: 'Trang trước',
          icon: const Icon(Icons.chevron_left),
          onPressed: _canBack ? () => _web?.goBack() : null,
        ),
        IconButton(
          tooltip: 'Trang sau',
          icon: const Icon(Icons.chevron_right),
          onPressed: _canForward ? () => _web?.goForward() : null,
        ),
        IconButton(
          tooltip: 'Tải lại',
          icon: const Icon(Icons.refresh),
          onPressed: () => _web?.reload(),
        ),
        Expanded(
          child: Text(
            _url ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(width: 12),
      ],
    );
  }
}
