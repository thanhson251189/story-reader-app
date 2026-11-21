import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import 'adapters/adapter_repository.dart';
import 'core/providers.dart';
import 'data/app_db.dart';
import 'fetcher/chapter_prefetcher.dart';
import 'fetcher/web_fetcher.dart';
import 'home_screen.dart';
import 'sources/registry.dart';
import 'tts/audio_handler.dart';
import 'tts/tts_player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = AdapterRepository([]);
  final db = AppDb();
  await SourceRegistry.restoreInstalled(db, repo);
  final fetcher = WebFetcher();
  final prefetcher = ChapterPrefetcher(
    db: db,
    fetcher: fetcher,
    adapters: repo,
  );
  final player = TtsPlayer(
    db: db,
    fetcher: fetcher,
    adapters: repo,
    prefetcher: prefetcher,
  );
  await Permission.notification.request();
  await AudioService.init(
    builder: () => TtsAudioHandler(player),
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'dev.storyreader.story_reader.audio',
      androidNotificationChannelName: 'Đọc truyện',
      androidNotificationOngoing: false,
      androidStopForegroundOnPause: true,
      androidNotificationIcon: 'mipmap/ic_launcher',
    ),
  );
  runApp(
    ProviderScope(
      overrides: [
        adapterRepoProvider.overrideWithValue(repo),
        appDbProvider.overrideWithValue(db),
        webFetcherProvider.overrideWithValue(fetcher),
        chapterPrefetcherProvider.overrideWithValue(prefetcher),
        ttsPlayerProvider.overrideWithValue(player),
      ],
      child: const StoryReaderApp(),
    ),
  );
  // Khởi tạo giọng nói SAU khi app đã hiện lên: engine TTS của một số máy có
  // thể đứng im không hồi đáp — chờ nó trước runApp là màn hình đen mãi.
  // Lỗi bỏ qua: phần đọc vẫn dùng được, phần nghe dùng cấu hình mặc định
  // rồi tự nạp cài đặt đã lưu khi engine trả lời.
  unawaited(
    player.init().catchError((Object e) {
      debugPrint('TTS init lỗi: $e');
    }),
  );
}

class StoryReaderApp extends StatelessWidget {
  const StoryReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Story Reader',
      debugShowCheckedModeBanner: false,
      // Nền tối toàn app đi theo cài đặt hệ thống; màn đọc vẫn tự quản
      // 3 lựa chọn riêng (sáng/tối/vàng) nên không bị ảnh hưởng.
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.brown,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.brown,
        brightness: Brightness.dark,
      ),
      themeMode: ThemeMode.system,
      navigatorObservers: [routeObserver],
      home: const HomeScreen(),
    );
  }
}
