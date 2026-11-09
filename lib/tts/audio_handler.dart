import 'package:audio_service/audio_service.dart';
import 'tts_player.dart';

class TtsAudioHandler extends BaseAudioHandler {
  final TtsPlayer player;

  TtsAudioHandler(this.player) {
    player.addListener(_sync);
    _sync();
  }

  void _sync() {
    final c = player.chapter;
    if (c != null) {
      mediaItem.add(MediaItem(
        id: c.url,
        title: c.title,
        artist: 'Story Reader',
        duration: null,
      ));
    }
    playbackState.add(playbackState.value.copyWith(
      processingState: player.loading
          ? AudioProcessingState.loading
          : (player.chunks.isEmpty ? AudioProcessingState.idle : AudioProcessingState.ready),
      playing: player.playing,
      controls: [
        MediaControl.skipToPrevious,
        player.playing ? MediaControl.pause : MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {MediaAction.playPause, MediaAction.skipToNext, MediaAction.skipToPrevious},
      androidCompactActionIndices: const [0, 1, 2],
      updatePosition: Duration.zero,
    ));
  }

  @override
  Future<void> play() => player.playing ? Future.value() : player.resume();

  @override
  Future<void> pause() => player.pause();

  @override
  Future<void> stop() async {
    await player.stop();
    await super.stop();
  }

  @override
  Future<void> skipToNext() => player.nextChapter();

  @override
  Future<void> skipToPrevious() => player.prevChapter();
}