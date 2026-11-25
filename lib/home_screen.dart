import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/app_notifications.dart';
import 'core/errors.dart';
import 'core/providers.dart';
import 'discover/discover_screen.dart';
import 'fetcher/story_downloader.dart';
import 'home/mini_player.dart';
import 'library/library_checker.dart';
import 'library/library_screen.dart';
import 'search/search_screen.dart';
import 'settings/settings_screen.dart';
import 'sources/registry.dart';
import 'update/app_updater.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  /// Thanh tab gọn hơn NavigationBar mặc định (80dp): nhường chiều cao cho
  /// nội dung, nhất là tab Khám phá đang xem web.
  static Widget navBar({
    required int index,
    required ValueChanged<int> onSelect,
  }) {
    return NavigationBar(
      height: 62,
      selectedIndex: index,
      onDestinationSelected: onSelect,
      labelTextStyle: const WidgetStatePropertyAll(
        TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
      ),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.local_library_outlined),
          selectedIcon: Icon(Icons.local_library),
          label: 'Thư viện',
        ),
        NavigationDestination(
          icon: Icon(Icons.search_outlined),
          selectedIcon: Icon(Icons.search),
          label: 'Tìm kiếm',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: 'Khám phá',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Cài đặt',
        ),
      ],
    );
  }

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // Thư viện là màn đầu: ô dán link không phải thứ người đọc cần thấy trước.
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_startupTasks().catchError((_) {}));
  }

  // Việc nền lúc mở app: nhắc cập nhật app, tự cập nhật nguồn truyện, tự
  // kiểm tra chương mới nếu đã lâu chưa kiểm. Nghỉ vài giây để không giành
  // mạng lúc app vừa mở. Lỗi cập nhật nguồn bỏ qua (lần mở sau thử lại);
  // lỗi kiểm tra chương mới thì báo, không im.
  Future<void> _startupTasks() async {
    final db = ref.read(appDbProvider);
    unawaited(AppUpdater.showIfAny(context, db).catchError((_) => false));
    await Future<void>.delayed(const Duration(seconds: 3));
    if (!mounted) return;
    try {
      final updated = await SourceRegistry(
        db,
        ref.read(adapterRepoProvider),
      ).autoUpdateInstalled();
      if (updated > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã tự cập nhật $updated nguồn truyện')),
        );
      }
    } catch (_) {}
    if (!mounted) return;
    if ((await db.getSetting('autoCheckNew') ?? '1') != '1') return;
    if (LibraryChecker.running) return;
    final last = int.tryParse(
      await db.getSetting(LibraryChecker.lastCheckKey) ?? '',
    );
    // Quét cả thư viện mỗi lần mở app dễ bị trang chặn và mất vài phút.
    // Cách vài giờ là đủ để thấy chương mới; nút trên thư viện vẫn kiểm tra ngay.
    if (!LibraryChecker.isDue(last, DateTime.now())) return;
    try {
      final res = await LibraryChecker.check(
        db: db,
        fetcher: ref.read(webFetcherProvider),
        repo: ref.read(adapterRepoProvider),
      );
      if (!res.ran || !mounted) return;
      await db.setSetting(
        LibraryChecker.lastCheckKey,
        '${DateTime.now().millisecondsSinceEpoch}',
      );
      if (res.cancelled || !mounted) return;
      final messenger = ScaffoldMessenger.of(context);
      // Bật thông báo thì đẩy ra notification hệ thống; tắt (hoặc máy từ
      // chối) thì giữ snackbar như cũ để không mất tin.
      var notified = false;
      if (res.fresh > 0 &&
          (await db.getSetting('notifyNewChapters') ?? '0') == '1') {
        notified = await AppNotifications.instance.showNewChapters(
          fresh: res.fresh,
          titles: res.freshTitles,
        );
      }
      if (!mounted) return;
      if (res.warns.isNotEmpty) {
        final head = res.fresh > 0
            ? '${res.fresh} truyện có chương mới'
            : 'Kiểm tra chương mới gặp lỗi';
        messenger.showSnackBar(
          SnackBar(content: Text('$head\n${res.warns.join('\n')}')),
        );
      } else if (res.fresh > 0 && !notified) {
        messenger.showSnackBar(
          SnackBar(content: Text('${res.fresh} truyện có chương mới')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Kiểm tra chương mới lỗi: ${friendlyError(e)}'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Back hệ thống: tab khác về Thư viện, Thư viện mới thoát. Tab Khám
      // phá tự xử lý (lùi lịch sử web rồi mới về Thư viện).
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_tab == 2) return;
        if (_tab != 0) {
          setState(() => _tab = 0);
          return;
        }
        SystemNavigator.pop();
      },
      child: Scaffold(
        body: IndexedStack(
          index: _tab,
          children: [
            LibraryScreen(
              active: _tab == 0,
              onExplore: () => setState(() => _tab = 2),
            ),
            SearchScreen(active: _tab == 1),
            DiscoverScreen(
              active: _tab == 2,
              onBackToLibrary: () => setState(() => _tab = 0),
            ),
            const SettingsScreen(),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Tải cả truyện chạy nền: đang ở tab khác vẫn thấy tiến độ và
            // nút dừng (tab Thư viện đã có dòng chi tiết riêng).
            if (_tab != 0) _downloadBar(),
            // Thanh nghe nằm trên thanh tab: đang nghe ở tab nào cũng thấy,
            // vào màn đọc thì màn đọc có thanh riêng nên không hiện trùng.
            const MiniPlayer(),
            HomeScreen.navBar(
              index: _tab,
              onSelect: (i) => setState(() => _tab = i),
            ),
          ],
        ),
      ),
    );
  }

  Widget _downloadBar() {
    return ValueListenableBuilder<StoryDownloadState?>(
      valueListenable: StoryDownloader.state,
      builder: (context, dl, _) {
        if (dl == null || !dl.running) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
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
        );
      },
    );
  }
}
