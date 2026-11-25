import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../adapters/adapter_repository.dart';
import '../core/errors.dart';
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
  // Tốc độ là speed tuyệt đối của just_audio (1.0 = bình thường) vì âm thanh
  // là file WAV synthesizeToFile rồi phát lại, không phải thang 0.5=chuẩn
  // của setSpeechRate (giá trị mặc định 0.5 cũ là để lại từ thời _tts.speak).
  double rate = 1.0;
  double pitch = 1.0;
  // Giữ màn hình sáng trong lúc nghe (tốn pin) — tuỳ chọn, mặc định tắt vì
  // âm thanh phát trong foreground service nên tắt màn hình vẫn nghe được.
  bool keepScreenOn = false;
  List<Map<String, String>> voices = [];
  Map<String, String>? currentVoice;
  String? voiceWarning;
  String? lastError;

  /// URL truyện màn đọc truyền lúc bấm nghe. Chương kế phải dùng đúng URL này
  /// thì sửa từ "chỉ truyện này" mới khớp — đoán từ link chương thì lệch.
  String? _readingStoryUrl;

  /// Tên truyện của phiên nghe hiện tại. Có tên thì thông báo khoá máy và
  /// mini-player nói đúng truyện, không chỉ tên chương.
  String? storyTitle;

  String? get readingStoryUrl => _readingStoryUrl;
  Timer? _sleepTimer;
  DateTime? sleepAt;
  bool _disposed = false;
  int _gen = 0;
  // Chỉ tăng khi người dùng chọn một chương cụ thể (phát, nhảy chương).
  // stop() tăng _gen để cắt tiếng nhưng không tăng cờ này: nghe hết chương
  // rồi bấm dừng vẫn được nạp chương kế ở trạng thái dừng.
  int _navGen = 0;
  Completer<void>? _resumeWait;
  Completer<void>? _chunkDone;
  Completer<void>? _synthIdle;
  // Bấm Play trên thông báo khi TTS đang tải chương kế: không phát ngay (sẽ
  // nhầm chương cũ vài giây) mà nhớ ý định, chương mới tải xong phát luôn.
  bool _playAfterLoad = false;

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

  // Tách câu dùng chung cho chunkify (TTS) và tô sáng câu đang đọc trong
  // reader: hai nơi phải cùng một quy tắc nếu không highlight sẽ lệch chunk.
  static final sentenceSplit = RegExp(r'(?<=[.!?…])\s+');

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
    rate = double.tryParse(await db.getSetting('ttsRate') ?? '') ?? 1.0;
    pitch = double.tryParse(await db.getSetting('ttsPitch') ?? '') ?? 1.0;
    keepScreenOn = (await db.getSetting('keepScreenOn') ?? '0') == '1';
    await _tts.setPitch(pitch);
    await reloadVoices();
    await _restoreVoice();
    if (langResult != 1 && viVoices.isEmpty) {
      voiceWarning = 'Máy chưa có giọng tiếng Việt. Vào Cài đặt > Ngôn ngữ & nhập liệu > Chuyển văn bản thành giọng nói để tải giọng Google tiếng Việt.';
    }
  }

  static bool isViVoice(Map<String, String> v) =>
      (v['locale'] ?? '').toLowerCase().startsWith('vi');

  // Nút nghe trên thẻ thư viện không đi qua màn đọc (nơi đang xin quyền),
  // nên xin ở đây một lần; bị từ chối thì vẫn nghe được, chỉ mất nút trên
  // màn khoá. Lỗi nền (test/máy lạ) bỏ qua, không chặn việc phát.
  Future<void> _ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    try {
      if (await Permission.notification.isGranted) return;
      await Permission.notification.request();
    } catch (_) {}
  }

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
          .split(sentenceSplit)
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

  Future<void> start(
    ChapterContent c, {
    int paraIndex = 0,
    String? storyUrl,
    String? storyTitle,
  }) async {
    if (storyUrl != null) {
      // Sang truyện khác mà nơi gọi không biết tên: bỏ tên truyện cũ để
      // mini-player/thông báo không hiện nhầm truyện trước.
      if (!sameChapterUrl(storyUrl, _readingStoryUrl)) this.storyTitle = null;
      _readingStoryUrl = storyUrl;
    }
    final title = storyTitle?.trim();
    if (title != null && title.isNotEmpty) this.storyTitle = title;
    _gen++;
    _navGen++;
    // start() là một lệnh phát mới từ nơi gọi — ý định chờ khi tải đã được
    // nơi đó biểu đạt trực tiếp, xoá cờ cũ để không còn ý định stale.
    _playAfterLoad = false;
    final gen = _gen;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    await _audio.stop();
    await _preview.stop();
    await _tts.stop();
    // Lệnh mới hơn (chuyển chương, dừng) đã tăng gen trong lúc chờ engine:
    // không ghi đè chương người dùng vừa chọn.
    if (gen != _gen) return;
    chapter = c;
    chunks = chunkify(c);
    _index = 0;
    if (paraIndex > 0) {
      final i = chunks.indexWhere((ch) => ch.paraIndex >= paraIndex);
      if (i > 0) _index = i;
    }
    lastError = null;
    playing = true;
    if (keepScreenOn) await WakelockPlus.enable();
    _notify();
    debugPrint('TTS start: ${c.title} (${chunks.length} chunks)');
    unawaited(_loop(gen));
  }

  /// Nghe một chương mà không cần màn đọc mở (nút trên thẻ thư viện). Tự tải
  /// chương, bổ sung chương trước/sau từ mục lục, lưu vị trí "đang đọc" rồi
  /// phát — cùng đường _loadChapter của chế độ nghe tự sang chương.
  Future<bool> playChapter(
    String url, {
    String? storyUrl,
    String? storyTitle,
    int paraIndex = 0,
  }) async {
    if (storyUrl != null) {
      if (!sameChapterUrl(storyUrl, _readingStoryUrl)) this.storyTitle = null;
      _readingStoryUrl = storyUrl;
    }
    final title = storyTitle?.trim();
    if (title != null && title.isNotEmpty) this.storyTitle = title;
    unawaited(_ensureNotificationPermission());
    try {
      final c = await _loadChapter(url);
      if (c == null) {
        lastError =
            'Không tải được chương. Mở truyện bằng tay để xem chi tiết.';
        _notify();
        return false;
      }
      // Thẻ thư viện thường có sẵn tên truyện; nếu không, lấy từ dòng thư viện
      // để mini-player không hiện link thô.
      if (this.storyTitle == null || this.storyTitle!.trim().isEmpty) {
        final story = storyUrl ?? storyUrlFromChapter(c.url);
        final lib = await db.getLibrary();
        for (final row in lib) {
          if (sameChapterUrl(row['story_url'] as String?, story)) {
            final t = (row['title'] as String?)?.trim();
            if (t != null && t.isNotEmpty) {
              this.storyTitle = t;
              break;
            }
          }
        }
      }
      final t = this.storyTitle?.trim();
      if (t != null && t.isNotEmpty) await db.setSetting('lastTitle', t);
      await start(c, paraIndex: paraIndex, storyUrl: storyUrl, storyTitle: t);
      return true;
    } catch (e) {
      lastError = 'Không tải được chương: ${friendlyError(e)}';
      _notify();
      return false;
    }
  }

  /// Đóng phiên nghe từ mini-player: dừng tiếng, bỏ chương đang giữ và hẹn
  /// giờ để thanh mini biến mất hẳn (khác stop() chỉ tạm dừng phiên).
  Future<void> closeSession() async {
    // Chặn lượt "hết chương tự nạp chương kế" đang chạy: nếu không, nó nạp
    // xong sẽ gán lại chapter và mini-player hiện lại ngay sau khi đóng.
    _navGen++;
    await stop();
    chapter = null;
    chunks = [];
    _index = 0;
    _readingStoryUrl = null;
    storyTitle = null;
    cancelSleepTimer();
    _notify();
  }

  static String _chunkFile(int i) => 'tts_chunk_${i % 2}.wav';

  Future<void> _loop(int gen) async {
    if (_index >= chunks.length) {
      await _chapterDone();
      return;
    }
    var file = await _synthRetry(
      chunks[_index].text,
      fileName: _chunkFile(_index),
      gen: gen,
    );
    var fails = 0;
    // Chỉ thoát khi đổi gen (start/stop/jump) hoặc hết chương. Lúc pause loop
    // chờ ở đây; resume() gọi start() với gen mới, đánh thức loop cũ thoát.
    while (gen == _gen) {
      if (file == null) {
        // Engine hỏng với đoạn này: bỏ qua NHƯNG phải báo người nghe biết;
        // hỏng hàng loạt (3 lần liền) thì dừng thay vì nuốt cả chương im lặng.
        fails++;
        if (fails >= 3) {
          lastError =
              'Không tạo được âm thanh đọc. Kiểm tra giọng đọc trong Cài '
              'đặt hệ thống rồi bấm nghe lại.';
          await stop();
          return;
        }
        lastError = 'Bỏ qua một đoạn không tạo được âm thanh.';
        _notify();
        _index++;
        if (_index >= chunks.length) {
          await _chapterDone();
          return;
        }
        file = await _synthRetry(
          chunks[_index].text,
          fileName: _chunkFile(_index),
          gen: gen,
        );
        continue;
      }
      fails = 0;
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
          ? await _synthRetry(
              chunks[_index].text,
              fileName: _chunkFile(_index),
              gen: gen,
            )
          : await prefetch;
    }
  }

  Future<String?> _synth(String text, {required String fileName}) async {
    // Chỉ chạy một synth tại một thời điểm: hai synth song song vừa khiến
    // engine trả lỗi (bị bỏ thành nuốt đoạn) vừa ghi đè cùng file chunk khi
    // đổi chương trong lúc synth đoạn kế của chương cũ. Người gọi sau chờ
    // người gọi trước xong bằng completer thay thế.
    while (_synthIdle != null) {
      await _synthIdle!.future;
    }
    _synthIdle = Completer<void>();
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

  /// Tạo âm thanh cho một đoạn, thử lại thêm 2 lần: engine TTS lỗi vặt
  /// (đang bận, thiếu bộ nhớ thoáng qua) thường hết ở lần kế. Trả về null nếu
  /// vẫn hỏng — người gọi quyết định bỏ qua có báo lỗi hay dừng hẳn.
  Future<String?> _synthRetry(
    String text, {
    required String fileName,
    required int gen,
  }) async {
    var file = await _synth(text, fileName: fileName);
    for (var r = 0; r < 2 && file == null; r++) {
      if (gen != _gen) return null;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      if (gen != _gen) return null;
      file = await _synth(text, fileName: fileName);
    }
    return file;
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
    final nav = _navGen;
    debugPrint('TTS chapter done: ${chapter?.title}');
    final next = chapter?.nextUrl;
    if (next == null) {
      if (nav != _navGen) return;
      await stop();
      return;
    }
    loading = true;
    _notify();
    try {
      final c = await _loadChapter(next);
      // Bấm chương trước/sau (hoặc phát một chương khác) trong lúc tải: lệnh
      // đó đã tăng _navGen. Không ghi chương tự chuyển đè lên chương vừa chọn,
      // và không tắt cờ loading của lệnh mới. stop() không tăng _navGen — dừng
      // nghe vẫn nạp chương kế ở trạng thái dừng.
      if (nav != _navGen) return;
      loading = false;
      if (c == null) {
        // Đường _jumpTo (bấm chương trước/sau trên thông báo) có báo lỗi thì
        // nghe hết chương cũng phải báo — dừng im lặng gây bối rối.
        lastError =
            'Không đọc được chương kế: chưa cài nguồn cho trang có chương '
            'này. Mở chương đó bằng tay để xem chi tiết.';
        await stop();
        return;
      }
      // Bấm Play giữa lúc tải chương kế: nạp xong phát luôn chương mới thay
      // vì nuốt ý định Play của người nghe.
      final wantPlay = _playAfterLoad;
      _playAfterLoad = false;
      if (nav != _navGen) return;
      // Trong lúc tải chương kế user có thể đã tạm dừng — nạp chương mới ở
      // trạng thái dừng, không tự bật lại tiếng.
      if (!playing && !wantPlay) {
        chapter = c;
        chunks = chunkify(c);
        _index = 0;
        _notify();
        return;
      }
      if (nav != _navGen) return;
      await start(c);
    } catch (e) {
      if (nav != _navGen) return;
      loading = false;
      lastError = 'Không tải được chương kế: ${friendlyError(e)}';
      await stop();
    }
  }

  Future<ChapterContent?> _loadChapter(String url) async {
    var c = await db.getCachedChapter(url);
    if (c == null) {
      final adapter = adapters.forUrl(url);
      if (adapter == null) return null;
      c = await fetcher.fetchChapter(url, adapter);
      // Nguồn không có nút prev/next trên trang: bổ sung chương kế từ mục
      // lục TRƯỚC khi cache — thiếu ở đây thì nghe hết chương không biết
      // sang đâu và tự tắt im lặng.
      c = await db.fillNav(c);
      await db.cacheChapter(c);
    } else {
      // Cache do bộ tải trước ghi có thể chưa kèm prev/next: bù trên bản
      // ghi nhớ (không ghi lại để không làm mới fetched_at).
      c = await db.fillNav(c);
    }
    // Nghe TTS chạy sang chương kế (hết chương tự chuyển hoặc bấm chương
    // trước/sau trên thông báo) cũng là đang đọc: lưu vị trí đọc tiếp và
    // cập nhật dòng "đang đọc" trong thư viện, kể cả khi chương lấy từ cache.
    await db.setSetting('lastUrl', url);
    await db.touchLibrary(storyUrlFromChapter(url), url);
    unawaited(prefetcher.prefetch(c.nextUrl));
    // Nghe cũng đọc bản đã sửa từ (cache giữ bản gốc — xem AppDb.fixWords).
    // Dùng URL truyện màn đọc đã truyền, không đoán từ link chương.
    return db.fixWords(c, storyUrl: await _storyUrlForFix(url));
  }

  Future<String> _storyUrlForFix(String chapterUrl) async {
    final known = _readingStoryUrl;
    if (known == null) return storyUrlFromChapter(chapterUrl);
    if (chapterBelongsToStory(chapterUrl, known, const [])) return known;
    final toc = await db.getToc(known);
    if (chapterBelongsToStory(chapterUrl, known, toc)) return known;
    final guessed = storyUrlFromChapter(chapterUrl);
    _readingStoryUrl = guessed;
    return guessed;
  }

  Future<void> pause() async {
    if (!playing) return;
    playing = false;
    await _audio.pause();
    await WakelockPlus.disable();
    _notify();
  }

  Future<void> resume() async {
    if (playing) return;
    // Bấm Play (nút media/thông báo) trong lúc đang tải chương kế: nếu start
    // ngay là phát nhầm chương cũ vài giây rồi mới tự chuyển. Nhớ ý định,
    // chương mới tải xong thì phát luôn đúng chương đó.
    if (loading) {
      _playAfterLoad = true;
      return;
    }
    if (chunks.isEmpty) return;
    final c = chapter;
    if (c == null) return;
    // Phát lại từ đầu đoạn văn đang nghe dở thay vì nối giữa chunk:
    // đường nối cũ bị câm sau pause, còn start() luôn synth + play lại đúng.
    await start(c, paraIndex: currentParaIndex);
  }

  Future<void> stop() async {
    _gen++;
    playing = false;
    loading = false;
    // Dừng là ý định rõ ràng: ý định Play chờ khi tải không còn giá trị.
    _playAfterLoad = false;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    await _audio.stop();
    await _preview.stop();
    await _tts.stop();
    await WakelockPlus.disable();
    // KHÔNG xoá hẹn giờ tắt ở đây: mở chương khác khi đang nghe cũng đi qua
    // stop() — người nghe đặt hẹn giờ 30 phút không bị mất vô cớ. Hẹn giờ
    // tự hủy khi kêu (pause() trên phiên đã dừng là không-op).
    _notify();
  }

  /// Tua lùi một chunk (khoảng 1–3 câu): nghe lại câu vừa rồi mà không phải
  /// dừng rồi bấm phát lại cả đoạn. Ở chunk đầu thì đọc lại từ đầu.
  Future<void> skipPrev() async {
    if (chapter == null || chunks.isEmpty) return;
    await _skipTo(_index <= 0 ? 0 : _index - 1);
  }

  /// Tua tới một chunk kế để bỏ qua đoạn không muốn nghe. Ở chunk cuối thì
  /// sang chương kế như khi nghe hết chương: đang phát thì phát tiếp chương
  /// mới, đang dừng thì chỉ dời vị trí (không tự bật tiếng). Không có chương
  /// kế thì nghe lại đoạn cuối như cũ.
  Future<void> skipNext() async {
    if (chapter == null || chunks.isEmpty) return;
    if (_index + 1 >= chunks.length) {
      final url = chapter?.nextUrl;
      if (url != null) {
        await _jumpTo(url);
        return;
      }
    }
    await _skipTo((_index + 1).clamp(0, chunks.length - 1));
  }

  /// Tua tới chunk [i]. Đang phát thì cắt chunk hiện tại và phát lại từ chunk
  /// đích (cùng máy start()); đang dừng thì chỉ dời vị trí nghe — lần resume kế
  /// qua nút media/headset đọc từ đoạn đó.
  Future<void> _skipTo(int i) async {
    if (!playing) {
      _index = i;
      _notify();
      return;
    }
    _gen++;
    final gen = _gen;
    _signalResume();
    _chunkDone?.complete();
    _chunkDone = null;
    // Chỉ pause, không stop: load file mới ở dưới tự thay nguồn đang phát,
    // còn stop() bỏ platform player cũ rồi phải dựng lại (chậm hơn, và thêm
    // một nguồn sự kiện phải nối lại).
    await _audio.pause();
    await _tts.stop();
    _index = i;
    lastError = null;
    playing = true;
    if (keepScreenOn) await WakelockPlus.enable();
    _notify();
    unawaited(_loop(gen));
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
    _navGen++;
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
        lastError =
            'Không tải được chương. Mở chương này bằng tay để xem chi tiết.';
        playing = false;
        _notify();
        return;
      }
      // Bấm Play giữa lúc tải chương (ý định đã nhớ): phát luôn chương mới
      // dù trước đó đang dừng.
      final wantPlay = _playAfterLoad;
      _playAfterLoad = false;
      if (wasPlaying || wantPlay) {
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
      lastError = 'Không tải được chương: ${friendlyError(e)}';
      _notify();
    }
  }

  Future<void> setRate(double v) async {
    rate = v;
    await _audio.setSpeed(v);
    await db.setSetting('ttsRate', v.toString());
    _notify();
  }

  Future<void> setKeepScreenOn(bool v) async {
    keepScreenOn = v;
    await db.setSetting('keepScreenOn', v ? '1' : '0');
    // Đang nghe thì áp dụng ngay, không đợi lần phát kế.
    if (playing) {
      if (v) {
        await WakelockPlus.enable();
      } else {
        await WakelockPlus.disable();
      }
    }
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
