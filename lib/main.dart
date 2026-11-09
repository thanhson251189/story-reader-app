import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'adapters/adapter_repository.dart';
import 'core/providers.dart';
import 'data/app_db.dart';
import 'fetcher/web_fetcher.dart';
import 'home_screen.dart';
import 'tts/audio_handler.dart';
import 'tts/tts_player.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final repo = await AdapterRepository.load();
  final db = AppDb();
  final fetcher = WebFetcher();
  final player = TtsPlayer(db: db, fetcher: fetcher, adapters: repo);
  final savedRate = double.tryParse(await db.getSetting('ttsRate') ?? '');
  if (savedRate != null) player.rate = savedRate;
  await player.init();
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
  runApp(ProviderScope(
    overrides: [
      adapterRepoProvider.overrideWithValue(repo),
      appDbProvider.overrideWithValue(db),
      webFetcherProvider.overrideWithValue(fetcher),
      ttsPlayerProvider.overrideWithValue(player),
    ],
    child: const StoryReaderApp(),
  ));
}

class StoryReaderApp extends StatelessWidget {
  const StoryReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Story Reader',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.brown,
        brightness: Brightness.light,
      ),
      home: const HomeScreen(),
    );
  }
}