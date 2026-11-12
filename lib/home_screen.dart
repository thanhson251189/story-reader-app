import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/providers.dart';
import 'home/read_tab.dart';
import 'library/library_screen.dart';
import 'search/search_screen.dart';
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
    unawaited(_warmRegistry());
    unawaited(AppUpdater.showIfAny(context).catchError((_) => false));
  }

  Future<void> _warmRegistry() async {
    try {
      await SourceRegistry(
        ref.read(appDbProvider),
        ref.read(adapterRepoProvider),
      ).loadIndex();
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
          const ReadTab(),
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
        ],
      ),
    );
  }
}
