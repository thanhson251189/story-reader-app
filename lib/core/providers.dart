import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../adapters/adapter_repository.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';
import '../tts/tts_player.dart';

final adapterRepoProvider = Provider<AdapterRepository>((ref) => throw UnimplementedError());
final appDbProvider = Provider<AppDb>((ref) => AppDb());
final webFetcherProvider = Provider<WebFetcher>((ref) => WebFetcher());
final ttsPlayerProvider = Provider<TtsPlayer>((ref) => throw UnimplementedError());