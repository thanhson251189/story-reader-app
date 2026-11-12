import 'dart:async';

import 'package:flutter/foundation.dart';

import '../adapters/adapter_repository.dart';
import '../data/app_db.dart';
import 'web_fetcher.dart';

/// Tải trước các chương kế tiếp vào cache, dùng chung cho màn đọc và TTS.
/// Tải tuần tự và nghỉ giữa các lần để mạng yếu vẫn theo kịp và nguồn
/// không chặn vì dồn request; chuỗi cũ tự huỷ khi có lệnh prefetch mới.
class ChapterPrefetcher {
  final AppDb db;
  final WebFetcher fetcher;
  final AdapterRepository adapters;

  static const defaultCount = 3;
  static const maxCount = 5;

  final Duration gap;
  int _gen = 0;

  ChapterPrefetcher({
    required this.db,
    required this.fetcher,
    required this.adapters,
    this.gap = const Duration(seconds: 5),
  });

  Future<void> prefetch(String? startUrl) async {
    final gen = ++_gen;
    final raw = int.tryParse(await db.getSetting('prefetchCount') ?? '');
    final count = (raw ?? defaultCount).clamp(1, maxCount);
    var url = startUrl;
    var fetched = 0;
    for (var i = 0; i < count && url != null && gen == _gen; i++) {
      if (url.startsWith('book:')) return;
      try {
        final cached = await db.getCachedChapter(url);
        if (gen != _gen) return;
        if (cached != null) {
          url = cached.nextUrl;
          continue;
        }
        final adapter = adapters.forUrl(url);
        if (adapter == null) return;
        if (fetched > 0) {
          await Future<void>.delayed(gap);
          if (gen != _gen) return;
        }
        final c = await fetcher.fetchChapter(url, adapter);
        if (gen != _gen) return;
        await db.cacheChapter(c);
        debugPrint('Prefetch xong: ${c.title}');
        fetched++;
        url = c.nextUrl;
      } catch (e) {
        debugPrint('Prefetch dừng ở $url: $e');
        return;
      }
    }
  }
}
