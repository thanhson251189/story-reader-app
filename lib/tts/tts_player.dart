import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../adapters/adapter_repository.dart';
import '../core/models.dart';
import '../data/app_db.dart';
import '../fetcher/chapter_prefetcher.dart';
import '../fetcher/web_fetcher.dart';

class SpeakChunk {
  final int paraIndex;
  final String text;
  SpeakChunk(this.paraIndex, this.text);
}

class TtsPlayer extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  final AudioPlayer _audio = AudioPlayer();
  final AudioPlayer _preview = AudioPlayer();
  final AppDb db;
  final WebFetcher fetcher;
  final AdapterRepository adapters;
  final ChapterPrefetcher prefetcher;

  List<SpeakChunk> chunks = [];
  int _index = 0;
  ChapterContent? chapter;
  bool playing = false;
  bool loading = false;
  double rate = 0.5;
  double pitch = 1.0;
  List<Map<String, String>> voices = [];
  Map<String, String>? currentVoice;
  String? voiceWarning;
  String? lastError;
  Timer? _sleepTimer;
  DateTime? sleepAt;
  bool _disposed = false;
  int _gen = 0;
  Completer<void>? _resumeWait;
  Completer<void>? _chunkDone;
  Completer<void>? _synthIdle;

  TtsPlayer({
    required this.db,
    required this.fetcher,
    required this.adapters,
    required this.prefetcher,
  }) {
    // Phát trong process của app (foreground service mediaPlayback) để
    // Android không chặn âm thanh nền như khi engine TTS tự phát.
    _audio.processingStateStream.listen((s) {
      if (s == ProcessingState.completed) {
        _chunkDone?.complete();
        _chunkDone = null;
      }
    });
  }

  int get currentParaIndex => chunks.isEmpty
      ? -1
      : chunks[_index.clamp(0, chunks.length - 1)].paraIndex;
  SpeakChunk? get currentChunk =>
      chunks.isEmpty ? null : chunks[_index.clamp(0, chunks.length - 1)];
  int get remainingSleepMinutes =>
      sleepAt == null ? 0 : sleepAt!.difference(DateTime.now()).inMinutes + 1;

  Future<void> init() async {
    final langResult = await _tts.setLanguage('vi-VN');
    await _tts.awaitSynthCompletion(true);
    await _tts.setVolume(1.0);
    rate = double.tryParse(await db.getSetting('ttsRate') ?? '') ?? 0.5;
    pitch = double.tryParse(await db.getSetting('ttsPitch') ?? '') ?? 1.0;
    await _tts.setPitch(pitch);
    await reloadVoices();
    await _restoreVoice();
    if (langResult != 1 && viVoices.isEmpty) {
      voiceWarning = 'Máy chưa có giọng tiếng Việt. Vào Cài đặt > Ngôn ngữ & nhập liệu > Chuyển văn bản thành giọng nói để tải giọng Google tiếng Việt.';
    }
  }

  static bool isViVoice(Map<String, String> v) =>
      (v['locale'] ?? '').toLowerCase().startsWith('vi');

  List<Map<String, String>> get viVoices => voices.where(isViVoice).toList();

  Future<void> reloadVoices() async {
    try {
      final raw = await _tts.getVoices as List?;
      voices =
          (raw ?? [])
              .whereType<Map>()
              .map(
                (m) => {
                  'name': '${m['name'] ?? ''}',
                  'locale': '${m['locale'] ?? ''}',
                  'quality': '${m['quality'] ?? ''}',
                  'network_required': '${m['network_required'] ?? '0'}',
                },
              )
              .where((m) => m['name']!.isNotEmpty)
              .toList()
            ..sort((a, b) {
              final av = isViVoice(a) ? 0 : 1;
              final bv = isViVoice(b) ? 0 : 1;
              if (av != bv) return av - bv;
              return a['locale']!.compareTo(b['locale']!);
            });
      debugPrint('TTS voices loaded: ${voices.length}, vi=${viVoices.length}');
      _notify();
    } catch (e) {
      debugPrint('TTS getVoices error: $e');
    }
  }

  Future<void> _restoreVoice() async {
    final raw = await db.getSetting('ttsVoice');
    if (raw == null || raw.isEmpty) return;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final name = m['name'] as String?;
      final locale = m['locale'] as String?;
      if (name == null || locale == null) return;
      final res = await _tts.setVoice({'name': name, 'locale': locale});
      if (res == 1) {
        currentVoice = voices.firstWhere(
          (v) => v['name'] == name && v['locale'] == locale,
          orElse: () => {'name': name, 'locale': locale},
        );
      } else {
        debugPrint('TTS saved voice not found: $name ($locale)');
      }
    } catch (_) {}
  }

  Future<bool> selectVoice(Map<String, String> v) async {
    final name = v['name'];
    final locale = v['locale'];
    if (name == null || locale == null) return false;
    final res = await _tts.setVoice({'name': name, 'locale': locale});
    if (res != 1) return false;
    currentVoice = Map<String, String>.from(v);
    await db.setSetting(
      'ttsVoice',
      jsonEncode({'name': name, 'locale': locale}),
    );
    _notify();
    return true;
  }

  Future<void> useDefaultVoice() async {
    // setLanguage đưa engine về giọng mặc định của vi-VN.
    await _tts.setLanguage('vi-VN');
    currentVoice = null;
    await db.setSetting('ttsVoice', '');
    _notify();
  }

  Future<void> setPitch(double v) async {
    pitch = v.clamp(0.5, 2.0).toDouble();
    await _tts.setPitch(pitch);
    await db.setSetting('ttsPitch', pitch.toString());
    _notify();
  }

  Future<String?> previewVoice() async {
    if (playing) await pause();
    while (_synthIdle != null) {
      await _synthIdle!.future;
    }
    const sample =
        'Xin chào! Đây là giọng đọc thử. Chúc bạn nghe truyện vui vẻ.';
    final file = await _synth(sample, fileName: 'tts_preview.wav');
    if (file == null) return null;
    await _preview.stop();
    await _preview.setFilePath(file);
    await _preview.setSpeed(rate);
    unawaited(_preview.play());
    debugPrint('TTS preview playing');
    return file;
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
    await _preview.stop();
    await _tts.stop();
    chapter = c;
    chunks = chunkify(c);
    _index = 0;
    if (paraIndex > 0) {
      final i = chunks.indexWhere((ch) => ch.paraIndex >= paraIndex);
      if (i > 0) _index = i;
    }
    lastError = null;
    playing = true;
    await WakelockPlus.enable();
    _notify();
    debugPrint('TTS start: ${c.title} (${chunks.length} chunks)');
    unawaited(_loop(gen));
  }

  static String _chunkFile(int i) => 'tts_chunk_${i % 2}.wav';

  Future<void> _loop(int gen) async {
    if (_index >= chunks.length) {
      await _chapterDone();
      return;
    }
    var file = await _synth(chunks[_index].text, fileName: _chunkFile(_index));
    // Chỉ thoát khi đổi gen (start/stop/jump) hoặc hết chương. Lúc tạm dừng phải
    // chờ trong _waitResume chứ không thoát vòng lặp, để resume() đánh thức lại
    // được; nếu thoát ở đây thì resume() không có cách nào phát tiếp (câm).
    while (gen == _gen) {
      if (file == null) {
        _index++;
        if (_index >= chunks.length) {
          await _chapterDone();
          return;
        }
        file = await _synth(chunks[_index].text, fileName: _chunkFile(_index));
        continue;
      }
      await _waitResume(gen);
      if (gen != _gen) return;
      await _audio.setFilePath(file);
      await _audio.setSpeed(rate);
      await _waitResume(gen);
      if (gen != _gen) return;
      _notify();
      final done = Completer<void>();
      _chunkDone = done;
      debugPrint(
        'TTS play #$_index t=${DateTime.now().millisecondsSinceEpoch}',
      );
      unawaited(_audio.play());
      // Synth đoạn kế trong lúc đoạn này phát (file parity khác nhau) để không hở khoảng lặng.
      final next = _index + 1;
      final prefetch = next < chunks.length
          ? _synth(chunks[next].text, fileName: _chunkFile(next))
          : null;
      await done.future;
      _chunkDone = null;
      debugPrint('TTS end #$_index t=${DateTime.now().millisecondsSinceEpoch}');
      if (gen != _gen) return;
      _index = next;
      if (_index >= chunks.length) {
        await _chapterDone();
        return;
      }
      file = prefetch == null
          ? await _synth(chunks[_index].text, fileName: _chunkFile(_index))
          : await prefetch;
    }
  }

  Future<String?> _synth(String text, {required String fileName}) async {
    _synthIdle ??= Completer<void>();
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/$fileName';
      // isFullPath=true: dùng overload File (fd mở phía app) để engine ghi
      // được vào cache riêng; mặc định false đi nhánh MediaStore và kẹt.
      final res = await _tts.synthesizeToFile(text, path, true);
      debugPrint('TTS synth res=$res exists=${File(path).existsSync()}');
      return res == 1 ? path : null;
    } catch (e) {
      debugPrint('TTS synth error: $e');
      return null;
    } finally {
      _synthIdle?.complete();
      _synthIdle = null;
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
    var c = await db.getCachedChapter(url);
    if (c == null) {
      final adapter = adapters.forUrl(url);
      if (adapter == null) return null;
      c = await fetcher.fetchChapter(url, adapter);
      await db.cacheChapter(c);
      await db.setSetting('lastUrl', url);
    }
    unawaited(prefetcher.prefetch(c.nextUrl));
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
    await _preview.stop();
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
    _gen++;
    playing = false;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    await _audio.stop();
    await _preview.stop();
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
        _index = 0;
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
    _preview.dispose();
    _tts.stop();
    super.dispose();
  }
}
