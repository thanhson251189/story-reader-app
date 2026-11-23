import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:story_reader/adapters/adapter_repository.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/fetcher/chapter_prefetcher.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/tts/tts_player.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

class FakeWakelock extends WakelockPlusPlatformInterface {
  @override
  Future<void> toggle({required bool enable}) async {}

  @override
  Future<bool> get enabled async => false;
}

class FakeAudioPlayer extends AudioPlayerPlatform {
  FakeAudioPlayer(super.id);

  // sync: event tới just_audio ngay khi add, không bị phát lại trạng thái cũ
  // khi play() broadcast tiếp (gây completed giả cho chunk kế).
  final events = StreamController<PlaybackEventMessage>.broadcast(sync: true);
  final calls = <String>[];
  bool _playing = false;

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream => events.stream;

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    calls.add('load');
    // just_audio đánh dấu event đầu tiên sau load là loading; event thứ hai
    // mới thành ready thật, nếu không trạng thái cũ (completed) bị phát lại.
    emit(ProcessingStateMessage.ready);
    emit(ProcessingStateMessage.ready);
    // Giống Android: load nguồn mới khi đang playing thì tự phát tiếp.
    if (_playing) calls.add('play');
    return LoadResponse(duration: const Duration(seconds: 1));
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    calls.add('play');
    _playing = true;
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    calls.add('pause');
    _playing = false;
    return PauseResponse();
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) async =>
      SetSpeedResponse();

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) async =>
      SetVolumeResponse();

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async =>
      SetLoopModeResponse();

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
    SetShuffleModeRequest request,
  ) async => SetShuffleModeResponse();

  @override
  Future<SeekResponse> seek(SeekRequest request) async => SeekResponse();

  @override
  Future<DisposeResponse> dispose(DisposeRequest request) async {
    calls.add('dispose');
    _playing = false;
    return DisposeResponse();
  }

  void emit(ProcessingStateMessage state) {
    events.add(
      PlaybackEventMessage(
        processingState: state,
        updateTime: DateTime.now(),
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        duration: const Duration(seconds: 1),
        icyMetadata: null,
        currentIndex: 0,
        androidAudioSessionId: null,
      ),
    );
  }

  void complete() => emit(ProcessingStateMessage.completed);
}

class FakeJustAudio extends JustAudioPlatform {
  final players = <FakeAudioPlayer>[];

  @override
  Future<AudioPlayerPlatform> init(InitRequest request) async {
    final p = FakeAudioPlayer(request.id);
    players.add(p);
    return p;
  }

  @override
  Future<DisposePlayerResponse> disposePlayer(
    DisposePlayerRequest request,
  ) async => DisposePlayerResponse();

  FakeAudioPlayer get playing =>
      players.lastWhere((p) => p.calls.contains('play'));

  // stop() rồi phát lại tạo platform player mới, phải đếm mọi player.
  int playCount() => players.fold(
    0,
    (n, p) => n + p.calls.where((x) => x == 'play').length,
  );
}

class FakeAppDb extends AppDb {
  final settings = <String, String>{};
  final cached = <String, ChapterContent>{};

  /// Mục lục giả lập cho chapterNeighbors (fillNav thật dùng nó).
  final toc = <String, List<ChapterRef>>{};

  /// URL trả chậm khi đọc cache — dùng để chen hành động của user vào giữa
  /// lúc TTS đang tải chương kế.
  final slowUrls = <String>{};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<ChapterContent?> getCachedChapter(String url) async {
    if (slowUrls.contains(url)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return cached[url];
  }

  @override
  Future<void> cacheChapter(ChapterContent c) async {
    cached[c.url] = c;
  }

  @override
  Future<void> touchLibrary(String storyUrl, String chapterUrl) async {}

  @override
  Future<(String?, String?)> chapterNeighbors(String chapterUrl) async {
    for (final chapters in toc.values) {
      for (var i = 0; i < chapters.length; i++) {
        if (chapters[i].url == chapterUrl) {
          return (
            i > 0 ? chapters[i - 1].url : null,
            i + 1 < chapters.length ? chapters[i + 1].url : null,
          );
        }
      }
    }
    return (null, null);
  }
}

Future<void> waitUntil(bool Function() cond, {int maxMs = 2000}) async {
  for (var i = 0; i * 5 < maxMs && !cond(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(cond(), isTrue, reason: 'hết thời gian chờ điều kiện');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeJustAudio ja;
  late FakeAppDb db;
  late List<String> synthTexts;
  // Giá trị trả về của synthesizeToFile: 1 = thành công, 0 = engine lỗi.
  int synthResult = 1;
  late TtsPlayer player;

  setUp(() {
    ja = FakeJustAudio();
    JustAudioPlatform.instance = ja;
    WakelockPlusPlatformInterface.instance = FakeWakelock();
    synthTexts = [];
    synthResult = 1;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
      call,
    ) async {
      if (call.method == 'synthesizeToFile') {
        synthTexts.add((call.arguments as Map)['text'] as String);
        return synthResult;
      }
      if (call.method == 'getVoices') return <Map<String, String>>[];
      return 1;
    });
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    db = FakeAppDb();
    final fetcher = WebFetcher();
    final adapters = AdapterRepository([]);
    player = TtsPlayer(
      db: db,
      fetcher: fetcher,
      adapters: adapters,
      prefetcher: ChapterPrefetcher(
        db: db,
        fetcher: fetcher,
        adapters: adapters,
      ),
    );
  });

  tearDown(() async {
    player.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  // Đoạn văn dài bị chunkify tách làm 2 chunk (>800 ký tự mỗi câu).
  final s1 = 'A${'a' * 899}.';
  final s2 = 'B${'b' * 899}.';
  ChapterContent chapter() => ChapterContent(
    url: 'https://x.com/chuong-1',
    title: 'Chương 1',
    paragraphs: ['$s1 $s2', 'Đoạn hai.'],
  );

  String chapterUrl(int i) => 'https://x.com/chuong-$i';

  test('pause giữa đoạn văn rồi resume phải đọc lại từ đầu đoạn đó', () async {
    final c = chapter();
    expect(TtsPlayer.chunkify(c).length, 3);

    await player.start(c);
    await waitUntil(() => synthTexts.isNotEmpty);
    expect(synthTexts.first, s1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    // Nghe hết chunk đầu, sang chunk thứ hai vẫn cùng đoạn văn 0.
    ja.playing.complete();
    await waitUntil(() => ja.playCount() >= 2);
    expect(player.currentParaIndex, 0);

    await player.pause();
    expect(
      ja.players.any((p) => p.calls.contains('pause')),
      isTrue,
    );
    final synthBefore = synthTexts.length;
    final playBefore = ja.playCount();

    await player.resume();
    await waitUntil(() => synthTexts.length > synthBefore);
    // Phải synth lại chunk ĐẦU của đoạn văn, không phải chunk đang nghe dở.
    expect(synthTexts[synthBefore], s1);
    await waitUntil(() => ja.playCount() > playBefore);
    expect(player.playing, isTrue);
    expect(player.currentChunk!.text, s1);
  });

  test('resume sau pause ở đoạn khác vẫn bắt đầu từ đầu đoạn đó', () async {
    final c = chapter();
    await player.start(c, paraIndex: 1);
    await waitUntil(() => synthTexts.isNotEmpty);
    expect(synthTexts.first, 'Đoạn hai.');
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    await player.pause();
    final synthBefore = synthTexts.length;
    await player.resume();
    await waitUntil(() => synthTexts.length > synthBefore);
    expect(synthTexts[synthBefore], 'Đoạn hai.');
    expect(player.playing, isTrue);
    expect(player.currentParaIndex, 1);
  });

  test('resume khi chưa phát gì thì không làm gì', () async {
    await player.resume();
    expect(synthTexts, isEmpty);
    expect(player.playing, isFalse);
  });

  test('skipNext khi đang phát phải chuyển sang chunk kế rồi đọc tiếp', () async {
    await player.start(chapter());
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));
    expect(player.currentChunk!.text, s1);

    await player.skipNext();
    // Đợi loop thật sự phát chunk đích (đặt _chunkDone mới) rồi mới kết thúc
    // nó — bắn completed sớm hơn thì event rơi vào lúc chưa có chunk đang nghe.
    await waitUntil(() => ja.playCount() >= 2);
    expect(player.currentChunk!.text, s2);
    expect(player.playing, isTrue);

    // Hết chunk tua tới thì đọc tiếp chunk sau của chương.
    ja.playing.complete();
    await waitUntil(() => player.currentChunk!.text == 'Đoạn hai.');
    expect(player.playing, isTrue);
  });

  test('skipPrev khi đang phát đọc lại chunk trước', () async {
    await player.start(chapter(), paraIndex: 1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));
    expect(player.currentChunk!.text, 'Đoạn hai.');

    await player.skipPrev();
    await waitUntil(() => player.currentChunk!.text == s2);
    expect(player.playing, isTrue);
  });

  test('skipPrev ở chunk đầu thì đọc lại từ đầu chương', () async {
    await player.start(chapter());
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    await player.skipPrev();
    await waitUntil(() => player.currentChunk!.text == s1);
    expect(player.playing, isTrue);
  });

  test('tua khi đang dừng chỉ dời vị trí: resume đọc từ đoạn đã tua', () async {
    await player.start(chapter(), paraIndex: 1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    await player.pause();
    await player.skipPrev();
    expect(player.currentChunk!.text, s2);
    expect(player.playing, isFalse);

    final synthBefore = synthTexts.length;
    await player.resume();
    await waitUntil(() => synthTexts.length > synthBefore);
    // Resume theo semantics đoạn văn: synth chunk ĐẦU đoạn 0.
    expect(synthTexts[synthBefore], s1);
    expect(player.playing, isTrue);
  });

  test('skipNext ở chunk cuối khi đang phát thì sang chương kế', () async {
    final c2 = ChapterContent(
      url: 'https://x.com/chuong-2',
      title: 'Chương 2',
      paragraphs: ['Đoạn hai.'],
    );
    final c1 = ChapterContent(
      url: 'https://x.com/chuong-1',
      title: 'Chương 1',
      paragraphs: ['$s1 $s2', 'Đoạn hai.'],
      nextUrl: c2.url,
    );
    db.cached[c2.url] = c2;
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));
    expect(player.currentChunk!.text, s1);

    // Tua lần lượt qua 3 chunk của chương 1...
    await player.skipNext();
    await waitUntil(() => ja.playCount() >= 2);
    await player.skipNext();
    await waitUntil(() => ja.playCount() >= 3);
    expect(player.currentChunk!.text, 'Đoạn hai.');

    // ...bấm lần nữa ở chunk cuối là sang chương 2, đọc tiếp không dừng.
    await player.skipNext();
    await waitUntil(() => player.chapter?.url == c2.url);
    await waitUntil(() => ja.playCount() >= 4);
    expect(player.playing, isTrue);
    expect(player.currentChunk!.text, 'Đoạn hai.');
  });

  test('skipNext ở chunk cuối khi đang dừng chỉ dời sang chương kế, không tự phát', () async {
    final c2 = ChapterContent(
      url: 'https://x.com/chuong-2',
      title: 'Chương 2',
      paragraphs: ['Đoạn hai.'],
    );
    final c1 = ChapterContent(
      url: 'https://x.com/chuong-1',
      title: 'Chương 1',
      paragraphs: ['$s1 $s2', 'Đoạn hai.'],
      nextUrl: c2.url,
    );
    db.cached[c2.url] = c2;
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));
    await player.pause();

    // Đang dừng: tua dời vị trí, chunk cuối thì sang chương 2 nhưng vẫn dừng.
    await player.skipNext();
    await player.skipNext();
    expect(player.currentChunk!.text, 'Đoạn hai.');
    expect(player.playing, isFalse);
    await player.skipNext();
    expect(player.chapter?.url, c2.url);
    expect(player.currentChunk!.text, 'Đoạn hai.');
    expect(player.playing, isFalse);
  });

  test('dừng nghe trong lúc TTS tải chương kế thì không tự bật lại tiếng', () async {
    final c2 = ChapterContent(
      url: 'https://x.com/chuong-2',
      title: 'Chương 2',
      paragraphs: ['Đoạn hai.'],
    );
    final c1 = ChapterContent(
      url: 'https://x.com/chuong-1',
      title: 'Chương 1',
      paragraphs: ['Đoạn một.'],
      nextUrl: c2.url,
    );
    db.cached[c2.url] = c2;
    db.slowUrls.add(c2.url);
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    // Hết chunk duy nhất → _chapterDone bắt đầu tải chương 2 (chậm 100ms)...
    ja.playing.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(player.loading, isTrue);

    // ...user dừng nghe giữa chừng (pause hoặc reader gọi stop khi mở
    // chương khác). Tải xong phải nạp chương mới ở trạng thái dừng.
    await player.pause();
    await waitUntil(() => player.loading == false);
    expect(player.chapter?.url, c2.url);
    expect(player.playing, isFalse);
  });

  test('synth lỗi vặt thì thử lại rồi bỏ qua đoạn CÓ báo lỗi', () async {
    synthResult = 0;
    await player.start(ChapterContent(
      url: 'https://x.com/chuong-1',
      title: 'Chương 1',
      paragraphs: ['Đoạn một.'],
    ));
    // 1 lần synth + 2 lần thử lại đều lỗi → bỏ qua đoạn; hết chương (không có
    // chương kế) nên dừng. Bắt buộc có thông báo, không được nuốt im lặng.
    await waitUntil(() => player.playing == false, maxMs: 6000);
    expect(synthTexts.length, 3, reason: 'phải thử lại 2 lần trước khi bỏ qua');
    expect(player.lastError, contains('Bỏ qua'));
    expect(player.playing, isFalse);
  });

  test('synth hỏng hàng loạt 3 lần liền thì dừng với thông báo rõ ràng', () async {
    synthResult = 0;
    await player.start(ChapterContent(
      url: 'https://x.com/chuong-1',
      title: 'Chương 1',
      paragraphs: ['A.', 'B.', 'C.', 'D.'],
    ));
    await waitUntil(() => player.playing == false, maxMs: 12000);
    // 3 đoạn × (1 + 2 lần thử lại): đoạn thứ 4 không bị synth nữa vì đã dừng.
    expect(synthTexts.length, 9);
    expect(player.lastError, contains('Không tạo được âm thanh'));
    expect(player.playing, isFalse);
  });

  test('nghe hết chương mà chương kế thiếu nguồn thì dừng kèm thông báo', () async {
    final c1 = ChapterContent(
      url: 'https://x.com/chuong-1',
      title: 'Chương 1',
      paragraphs: ['Đoạn một.'],
      nextUrl: 'https://other-domain.com/chuong-2',
    );
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));
    ja.playing.complete();
    await waitUntil(() => player.playing == false, maxMs: 4000);
    expect(player.lastError, contains('chương kế'));
    expect(player.playing, isFalse);
  });

  test('nghe tự sang chương kế trên nguồn không có nút prev/next', () async {
    // Mô phỏng dammyy/docln: chương fetch về không có nextUrl, nav suy từ
    // mục lục. Bộ tải trước đã cache chương 2, 3 KHÔNG kèm prev/next.
    db.toc['https://x.com/truyen'] = [
      for (var i = 1; i <= 3; i++)
        ChapterRef(title: 'Chương $i', url: chapterUrl(i)),
    ];
    for (var i = 2; i <= 3; i++) {
      db.cached[chapterUrl(i)] = ChapterContent(
        url: chapterUrl(i),
        title: 'Chương $i',
        paragraphs: ['Đoạn một.'],
      );
    }
    // Chương 1 mở bằng tay: có nextUrl (đã fill từ mục lục).
    await player.start(
      ChapterContent(
        url: chapterUrl(1),
        title: 'Chương 1',
        paragraphs: ['Đoạn một.'],
        nextUrl: chapterUrl(2),
      ),
    );
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    // Hết chương 1 → sang chương 2 (cache không nav → fillNav phải bù).
    ja.playing.complete();
    await waitUntil(() => player.chapter?.url == chapterUrl(2), maxMs: 6000);
    await waitUntil(() => ja.playCount() >= 2);
    // Hết chương 2 → VẪN phải sang chương 3 (đây là chỗ trước đây dừng im lặng).
    ja.playing.complete();
    await waitUntil(() => player.chapter?.url == chapterUrl(3), maxMs: 6000);
    await waitUntil(() => ja.playCount() >= 3);
    // Hết chương 3 (cuối mục lục) → dừng là đúng.
    ja.playing.complete();
    await waitUntil(() => player.playing == false, maxMs: 4000);
  });

  test('bấm Play trong lúc tải chương kế thì chương mới phát khi tải xong', () async {
    final c2 = ChapterContent(
      url: chapterUrl(2),
      title: 'Chương 2',
      paragraphs: ['Đoạn hai.'],
    );
    final c1 = ChapterContent(
      url: chapterUrl(1),
      title: 'Chương 1',
      paragraphs: ['Đoạn một.'],
      nextUrl: chapterUrl(2),
    );
    db.cached[c2.url] = c2;
    db.slowUrls.add(c2.url);
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    // Hết chương 1 → TTS tải chương 2 (chậm 100ms)...
    ja.playing.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(player.loading, isTrue);

    // ...user bấm Play giữa lúc tải: KHÔNG được phát nhầm chương cũ (bắt
    // sự đó không synth lại đoạn chương cũ).
    final synthBefore = synthTexts.length;
    await player.resume();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(
      synthTexts.length,
      synthBefore,
      reason: 'phát nhầm chương cũ là synth lại đoạn cũ ngay lập tức',
    );

    // Tải xong: chương mới nạp và phát luôn — ý định Play không bị nuốt.
    await waitUntil(() => player.chapter?.url == c2.url, maxMs: 4000);
    expect(player.playing, isTrue);
    await waitUntil(() => synthTexts.contains('Đoạn hai.'), maxMs: 4000);
    expect(player.currentChunk!.text, 'Đoạn hai.');
  });

  test('bấm Play chờ tải rồi dừng hẳn thì không tự bật lại tiếng', () async {
    final c2 = ChapterContent(
      url: chapterUrl(2),
      title: 'Chương 2',
      paragraphs: ['Đoạn hai.'],
    );
    final c1 = ChapterContent(
      url: chapterUrl(1),
      title: 'Chương 1',
      paragraphs: ['Đoạn một.'],
      nextUrl: chapterUrl(2),
    );
    db.cached[c2.url] = c2;
    db.slowUrls.add(c2.url);
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    ja.playing.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(player.loading, isTrue);

    // Bấm Play (nhớ ý định) rồi dừng hẳn (mở chương khác, vuốt tắt thông
    // báo): ý định Play phải bị xoá, tải xong vẫn dừng. Chờ theo CHƯƠNG được
    // nạp chứ không phải loading — stop() tự đặt loading=false ngay khi đang
    // tải, chưa đủ nghĩa "tải xong".
    await player.resume();
    await player.stop();
    await waitUntil(() => player.chapter?.url == c2.url, maxMs: 4000);
    expect(player.playing, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(
      synthTexts.contains('Đoạn hai.'),
      isFalse,
      reason: 'dừng hẳn rồi thì không synth phát chương mới',
    );
  });

  test('bấm chương trước trong lúc tự sang chương kế thì không bị kéo về chương sau', () async {
    final c0 = ChapterContent(
      url: chapterUrl(0),
      title: 'Chương 0',
      paragraphs: const ['Chương trước.'],
      nextUrl: chapterUrl(1),
    );
    final c2 = ChapterContent(
      url: chapterUrl(2),
      title: 'Chương 2',
      paragraphs: const ['Chương sau.'],
    );
    final c1 = ChapterContent(
      url: chapterUrl(1),
      title: 'Chương 1',
      paragraphs: const ['Đoạn một.'],
      prevUrl: c0.url,
      nextUrl: c2.url,
    );
    db.cached[c0.url] = c0;
    db.cached[c2.url] = c2;
    db.slowUrls.add(c2.url);
    await player.start(c1);
    await waitUntil(() => ja.players.any((p) => p.calls.contains('play')));

    ja.playing.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(player.loading, isTrue);

    await player.prevChapter();
    await waitUntil(() => player.loading == false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(player.chapter?.url, c0.url);
    expect(player.playing, isTrue);
  });
}