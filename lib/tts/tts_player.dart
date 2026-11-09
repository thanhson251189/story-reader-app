import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
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
  final AudioPlayer _audio = AudioPlayer();
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
  int _gen = 0;
  Completer<void>? _resumeWait;
  Completer<void>? _chunkDone;

  TtsPlayer({required this.db, required this.fetcher, required this.adapters}) {
    // Phát trong process của app (foreground service mediaPlayback) để
    // Android không chặn âm thanh nền như khi engine TTS tự phát.
    _audio.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) {
        _chunkDone?.complete();
        _chunkDone = null;
      }
    });
  }

  int get currentParaIndex =>
      chunks.isEmpty ? -1 : chunks[index.clamp(0, chunks.length - 1)].paraIndex;
  SpeakChunk? get currentChunk =>
      chunks.isEmpty ? null : chunks[index.clamp(0, chunks.length - 1)];
  int get remainingSleepMinutes => sleepAt == null
      ? 0
      : sleepAt!.difference(DateTime.now()).inMinutes + 1;

  Future<void> init() async {
    final langResult = await _tts.setLanguage('vi-VN');
    await _tts.awaitSynthCompletion(true);
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
    _gen++;
    final gen = _gen;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    await _audio.stop();
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
    unawaited(_loop(gen));
  }

  Future<void> _loop(int gen) async {
    while (gen == _gen && playing) {
      if (index >= chunks.length) {
        await _chapterDone();
        return;
      }
      _notify();
      final file = await _synth(chunks[index].text);
      if (gen != _gen) return;
      await _waitResume(gen);
      if (gen != _gen || !playing) return;
      if (file == null) {
        index++;
        continue;
      }
      await _audio.setFilePath(file);
      await _audio.setSpeed(rate);
      if (gen != _gen || !playing) return;
      final done = Completer<void>();
      _chunkDone = done;
      unawaited(_audio.play());
      await done.future;
      _chunkDone = null;
      if (gen != _gen) return;
      index++;
    }
  }

  Future<String?> _synth(String text) async {
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/tts_chunk.wav';
      // isFullPath=true: dùng overload File (fd mở phía app) để engine ghi
      // được vào cache riêng; mặc định false đi nhánh MediaStore và kẹt.
      final res = await _tts.synthesizeToFile(text, path, true);
      debugPrint('TTS synth res=$res exists=${File(path).existsSync()}');
      return res == 1 ? path : null;
    } catch (e) {
      debugPrint('TTS synth error: $e');
      return null;
    }
  }

  Future<void> _waitResume(int gen) async {
    while (!playing && gen == _gen) {
      _resumeWait ??= Completer<void>();
      await _resumeWait!.future;
    }
  }

  void _signalResume() {
    _resumeWait?.complete();
    _resumeWait = null;
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
    await _audio.pause();
    await WakelockPlus.disable();
    _notify();
  }

  Future<void> resume() async {
    if (playing || chunks.isEmpty) return;
    playing = true;
    await WakelockPlus.enable();
    _notify();
    _signalResume();
    if (!_audio.playing && _audio.processingState == ProcessingState.ready) {
      await _audio.play();
    }
  }

  Future<void> stop() async {
    _gen++;
    playing = false;
    loading = false;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    await _audio.stop();
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
    _gen++;
    playing = false;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    await _audio.stop();
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
    await _audio.setSpeed(v);
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
    _gen++;
    _sleepTimer?.cancel();
    _signalResume();
    _chunkDone?.complete();
    _audio.dispose();
    _tts.stop();
    super.dispose();
  }
}