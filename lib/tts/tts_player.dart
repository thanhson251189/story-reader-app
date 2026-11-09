import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../adapters/adapter_repository.dart';
import '../core/models.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';

class SpeakChunk {
  final int paraIndex;
  final String text;
  SpeakChunk(this.paraIndex, this.text);
}

class TtsPlayer extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  final AppDb db;
  final WebFetcher fetcher;
  final AdapterRepository adapters;

  List<SpeakChunk> chunks = [];
  int index = 0;
  ChapterContent? chapter;
  bool playing = false;
  bool loading = false;
  double rate = 0.5;
  String? voiceWarning;
  String? lastError;
  Timer? _sleepTimer;
  DateTime? sleepAt;
  bool _disposed = false;

  TtsPlayer({required this.db, required this.fetcher, required this.adapters});

  int get currentParaIndex =>
      chunks.isEmpty ? -1 : chunks[index.clamp(0, chunks.length - 1)].paraIndex;
  SpeakChunk? get currentChunk =>
      chunks.isEmpty ? null : chunks[index.clamp(0, chunks.length - 1)];
  int get remainingSleepMinutes => sleepAt == null
      ? 0
      : sleepAt!.difference(DateTime.now()).inMinutes + 1;

  Future<void> init() async {
    final langResult = await _tts.setLanguage('vi-VN');
    await _tts.setSpeechRate(rate);
    await _tts.setPitch(1.0);
    await _tts.setVolume(1.0);
    try {
      final voices = await _tts.getVoices as List?;
      final viVoices = voices
          ?.where((v) => v.toString().toLowerCase().contains('vi'))
          .toList();
      debugPrint('TTS vi voices: $viVoices (langResult=$langResult)');
      if (langResult != 1 && (viVoices == null || viVoices.isEmpty)) {
        voiceWarning =
            'Máy chưa có giọng tiếng Việt. Vào Cài đặt > Ngôn ngữ & nhập liệu > Chuyển văn bản thành giọng nói để tải giọng Google tiếng Việt.';
      }
    } catch (_) {}
    _tts.setCompletionHandler(_onChunkComplete);
    _tts.setCancelHandler(() {});
    _tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
      _onChunkComplete();
    });
  }

  static List<SpeakChunk> chunkify(ChapterContent c) {
    final out = <SpeakChunk>[];
    for (var i = 0; i < c.paragraphs.length; i++) {
      final sentences = c.paragraphs[i]
          .split(RegExp(r'(?<=[.!?…])\s+'))
          .where((s) => s.trim().isNotEmpty)
          .toList();
      final merged = <String>[];
      var buf = '';
      for (final s in sentences) {
        if (buf.isEmpty) {
          buf = s;
        } else if (buf.length + s.length < 800) {
          buf += ' $s';
        } else {
          merged.add(buf);
          buf = s;
        }
        while (buf.length > 1500) {
          var cut = buf.lastIndexOf(' ', 1500);
          if (cut < 200) cut = 1500;
          merged.add(buf.substring(0, cut));
          buf = buf.substring(cut).trim();
        }
      }
      if (buf.isNotEmpty) merged.add(buf);
      for (final m in merged) {
        out.add(SpeakChunk(i, m));
      }
    }
    return out;
  }

  Future<void> start(ChapterContent c, {int paraIndex = 0}) async {
    chapter = c;
    chunks = chunkify(c);
    index = 0;
    if (paraIndex > 0) {
      final i = chunks.indexWhere((ch) => ch.paraIndex >= paraIndex);
      if (i > 0) index = i;
    }
    lastError = null;
    playing = true;
    await WakelockPlus.enable();
    _notify();
    debugPrint('TTS start: ${c.title} (${chunks.length} chunks)');
    await _speakCurrent();
  }

  Future<void> _speakCurrent() async {
    if (!playing || _disposed) return;
    if (index >= chunks.length) {
      await _chapterDone();
      return;
    }
    _notify();
    await _tts.speak(chunks[index].text);
  }

  void _onChunkComplete() {
    if (!playing || _disposed) return;
    index++;
    _speakCurrent();
  }

  Future<void> _chapterDone() async {
    debugPrint('TTS chapter done: ${chapter?.title}');
    final next = chapter?.nextUrl;
    if (next == null) {
      await stop();
      return;
    }
    loading = true;
    _notify();
    try {
      final c = await _loadChapter(next);
      loading = false;
      if (c == null) {
        await stop();
        return;
      }
      await start(c);
    } catch (e) {
      loading = false;
      lastError = 'Không tải được chương kế: $e';
      await stop();
    }
  }

  Future<ChapterContent?> _loadChapter(String url) async {
    final cached = await db.getCachedChapter(url);
    if (cached != null) return cached;
    final adapter = adapters.forUrl(url);
    if (adapter == null) return null;
    final c = await fetcher.fetchChapter(url, adapter);
    await db.cacheChapter(c);
    await db.setSetting('lastUrl', url);
    return c;
  }

  Future<void> pause() async {
    if (!playing) return;
    playing = false;
    await _tts.pause();
    await WakelockPlus.disable();
    _notify();
  }

  Future<void> resume() async {
    if (playing || chunks.isEmpty) return;
    playing = true;
    await WakelockPlus.enable();
    _notify();
    await _speakCurrent();
  }

  Future<void> stop() async {
    playing = false;
    loading = false;
    await _tts.stop();
    await WakelockPlus.disable();
    cancelSleepTimer();
    _notify();
  }

  Future<void> nextChapter() async {
    final url = chapter?.nextUrl;
    if (url == null) return;
    await _jumpTo(url);
  }

  Future<void> prevChapter() async {
    final url = chapter?.prevUrl;
    if (url == null) return;
    await _jumpTo(url);
  }

  Future<void> _jumpTo(String url) async {
    final wasPlaying = playing;
    await _tts.stop();
    loading = true;
    _notify();
    try {
      final c = await _loadChapter(url);
      loading = false;
      if (c == null) {
        lastError = 'Không tải được chương';
        playing = false;
        _notify();
        return;
      }
      if (wasPlaying) {
        await start(c);
      } else {
        chapter = c;
        chunks = chunkify(c);
        index = 0;
        _notify();
      }
    } catch (e) {
      loading = false;
      playing = false;
      lastError = 'Không tải được chương: $e';
      _notify();
    }
  }

  Future<void> setRate(double v) async {
    rate = v;
    await _tts.setSpeechRate(v);
    await db.setSetting('ttsRate', v.toString());
    _notify();
  }

  void setSleepTimer(int minutes) {
    cancelSleepTimer();
    if (minutes <= 0) return;
    sleepAt = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer(Duration(minutes: minutes), () async {
      debugPrint('TTS sleep timer fired');
      await pause();
      sleepAt = null;
      _notify();
    });
    _notify();
  }

  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sleepTimer?.cancel();
    _tts.stop();
    super.dispose();
  }
}