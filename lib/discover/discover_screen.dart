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
import '../sources/source_login_screen.dart';
import '../sources/sources_screen.dart';
import 'discover_opener.dart';

/// Tab Khám phá: mở trang chủ của từng nguồn ngay trong app, để người chưa
/// biết đọc gì vẫn xem được danh sách truyện như trên web. Bấm "Mở bằng app"
/// thì nhận diện trang truyện/chương rồi đọc hoặc lưu vào thư viện.
class DiscoverScreen extends ConsumerStatefulWidget {
  final bool active;

  /// Bấm Back hệ thống khi trang web không lùi được nữa: về tab Thư viện
  /// thay vì thoát app (người mới hay bấm Back khi đang xem web).
  final VoidCallback? onBackToLibrary;
  const DiscoverScreen({super.key, required this.active, this.onBackToLibrary});

  static String homeUrl(SourceAdapter a) => 'https://${a.domain}/';

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen> {
  InAppWebViewController? _web;
  String? _preferred;
  String? _url;
  bool _canBack = false;
  bool _canForward = false;
  bool _pageLoading = true;
  bool _opening = false;
  bool _hideAdult = false;
  Set<String> _adultDomains = {};
  Map<String, String> _names = {};

  @override
  void initState() {
    super.initState();
    _loadPreferred();
  }

  Future<void> _loadPreferred() async {
    try {
      final db = ref.read(appDbProvider);
      final saved = await db.getSetting('discoverSource');
      final hideAdult = await SourceRegistry.hideAdultEnabled(db);
      final adult = await SourceRegistry.adultDomains(db);
      final overrides = await loadAdapterNames(db);
      final cache = await db.getSetting('registryIndexCache');
      if (mounted) {
        setState(() {
          _preferred = saved;
          _hideAdult = hideAdult;
          _adultDomains = adult;
          _names = SourceRegistry.namesFromCache(cache, overrides);
        });
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(DiscoverScreen old) {
    super.didUpdateWidget(old);
    // Tab nằm trong IndexedStack: cài thêm nguồn ở màn khác rồi quay lại phải
    // thấy nguồn mới trong danh sách nguồn; đổi công tắc ẩn 18+ cũng áp ngay.
    if (widget.active && !old.active) unawaited(_loadPreferred());
  }

  List<SourceAdapter> get _sources => [...ref.read(adapterRepoProvider).all]
    ..removeWhere(
      (a) => _hideAdult && SourceRegistry.isAdultHost(a.domain, _adultDomains),
    )
    ..sort((a, b) => a.domain.compareTo(b.domain));

  /// Mở màn Nguồn truyện để chọn nguồn; bấm "Mở" ở một nguồn trả domain về
  /// đây và tab Khám phá mở đúng trang nguồn đó.
  Future<void> _openSources() async {
    final domain = await Navigator.push<String>(
      context,
      MaterialPageRoute(
        builder: (_) => const SourcesScreen(openInDiscover: true),
      ),
    );
    if (!mounted) return;
    if (domain != null && domain.isNotEmpty) {
      _select(domain);
    } else {
      setState(() {});
    }
    unawaited(_refreshNames());
  }

  /// Tên hiển thị có thể đổi sau khi cài/đổi tên nguồn ở màn Nguồn — đọc lại
  /// riêng tên, không đụng nguồn đang chọn.
  Future<void> _refreshNames() async {
    try {
      final db = ref.read(appDbProvider);
      final overrides = await loadAdapterNames(db);
      final cache = await db.getSetting('registryIndexCache');
      if (mounted) {
        setState(() => _names = SourceRegistry.namesFromCache(cache, overrides));
      }
    } catch (_) {}
  }

  /// Back hệ thống: lùi lịch sử web trước, hết thì về tab Thư viện.
  Future<void> handleBack() async {
    final web = _web;
    if (web != null) {
      try {
        if (await web.canGoBack()) {
          await web.goBack();
          return;
        }
      } catch (_) {}
    }
    widget.onBackToLibrary?.call();
  }

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
          SnackBar(
            content: Text('Không mở được bằng app: ${friendlyError(e)}'),
          ),
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
      // Chọn đọc một truyện từ trang nguồn nghĩa là muốn giữ nó: lưu luôn,
      // kẻo đọc xong quay lại Thư viện không thấy truyện.
      if (!inLib) await _saveStory(page, title, silent: true);
      if (!mounted) return;
      final start =
          savedLast ??
          (info.chapters.isEmpty ? page.url : info.chapters.first.url);
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ReaderScreen(url: start, storyUrl: page.url, storyTitle: title),
        ),
      );
    } else if (action == 'save') {
      await _saveStory(page, title);
    }
  }

  Future<void> _saveStory(
    DiscoverPage page,
    String title, {
    bool silent = false,
  }) async {
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
      if (!mounted || silent) return;
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
    // Không dùng AppBar: tên tab đã ở thanh dưới, bỏ đi để web có thêm chỗ.
    return PopScope(
      // Chặn Back khi tab Khám phá đang hiện để lùi lịch sử web trước;
      // các tab khác để HomeScreen xử lý.
      canPop: !widget.active,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        unawaited(handleBack());
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: sources.isEmpty
              ? _empty()
              : Column(
                  children: [
                    _toolbar(),
                    SizedBox(
                      height: 2,
                      child: _pageLoading
                          ? const LinearProgressIndicator(minHeight: 2)
                          : null,
                    ),
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
        ),
      ),
    );
  }

  IconButton _navIcon(IconData icon, String tip, VoidCallback? onPressed) {
    return IconButton(
      tooltip: tip,
      visualDensity: VisualDensity.compact,
      iconSize: 22,
      icon: Icon(icon),
      onPressed: onPressed,
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
              'Chưa có nguồn truyện',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Vào Nguồn truyện để cài nguồn, rồi quay lại đây để xem trang '
              'của nguồn ngay trong app.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.tonalIcon(
              onPressed: _openSources,
              icon: const Icon(Icons.dns_outlined),
              label: const Text('Cài nguồn truyện'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    final host = Uri.tryParse(_url ?? '')?.host ?? '';
    return Row(
      children: [
        _navIcon(
          Icons.chevron_left,
          'Trang trước',
          _canBack ? () => _web?.goBack() : null,
        ),
        _navIcon(
          Icons.chevron_right,
          'Trang sau',
          _canForward ? () => _web?.goForward() : null,
        ),
        _navIcon(Icons.refresh, 'Tải lại', () => _web?.reload()),
        Expanded(
          child: Tooltip(
            message: _url ?? '',
            child: Text(
              host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        // Đổi nguồn ngay tại đây (2 chạm) thay vì phải mở hẳn màn Nguồn.
        PopupMenuButton<String>(
          tooltip: 'Chọn nguồn',
          iconSize: 22,
          icon: const Icon(Icons.dns_outlined),
          onSelected: (v) {
            if (v == '__manage__') {
              unawaited(_openSources());
            } else {
              _select(v);
            }
          },
          itemBuilder: (_) {
            final current = _effectiveDomain(_sources);
            return [
              for (final a in _sources)
                CheckedPopupMenuItem(
                  value: a.domain,
                  checked: a.domain == current,
                  child: Text(_labelOf(a.domain)),
                ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: '__manage__',
                child: Text('Quản lý nguồn…'),
              ),
            ];
          },
        ),
        const SizedBox(width: 4),
        FilledButton.tonalIcon(
          onPressed: _opening || _pageLoading ? null : _openInApp,
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            minimumSize: const Size(0, 34),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: _opening
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_stories, size: 18),
          label: Text(_opening ? 'Đang nhận diện...' : 'Mở bằng app'),
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  String _labelOf(String domain) =>
      SourceRegistry.labelFor(domain, _names);
}
