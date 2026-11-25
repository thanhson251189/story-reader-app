import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/errors.dart';
import 'core/providers.dart';
import 'discover/discover_screen.dart';
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
      if (res.warns.isNotEmpty) {
        final head = res.fresh > 0
            ? '${res.fresh} truyện có chương mới'
            : 'Kiểm tra chương mới gặp lỗi';
        messenger.showSnackBar(
          SnackBar(content: Text('$head\n${res.warns.join('\n')}')),
        );
      } else if (res.fresh > 0) {
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
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          LibraryScreen(active: _tab == 0),
          const SearchScreen(),
          DiscoverScreen(active: _tab == 2),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: HomeScreen.navBar(
        index: _tab,
        onSelect: (i) => setState(() => _tab = i),
      ),
    );
  }
}
