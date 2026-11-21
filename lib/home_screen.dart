import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'home/read_tab.dart';
import 'library/library_checker.dart';
import 'library/library_screen.dart';
import 'search/search_screen.dart';
import 'settings/settings_screen.dart';
import 'sources/registry.dart';
import 'update/app_updater.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _tab = 2;

  @override
  void initState() {
    super.initState();
    unawaited(_startupTasks().catchError((_) {}));
  }

  // Việc nền lúc mở app: nhắc cập nhật app, tự cập nhật nguồn truyện, tự
  // kiểm tra chương mới. Chạy sau một khoảng nghỉ để không giành mạng lúc
  // app vừa cất cánh; lỗi bất kỳ thì bỏ qua — người dùng không cần biết.
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
    try {
      final res = await LibraryChecker.check(
        db: db,
        fetcher: ref.read(webFetcherProvider),
        repo: ref.read(adapterRepoProvider),
      );
      if (res.fresh > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${res.fresh} truyện có chương mới')),
        );
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          LibraryScreen(active: _tab == 0),
          const SearchScreen(),
          ReadTab(active: _tab == 2),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
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
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories),
            label: 'Đọc',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Cài đặt',
          ),
        ],
      ),
    );
  }
}
