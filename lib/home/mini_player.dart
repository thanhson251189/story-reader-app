import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../reader/reader_screen.dart';

/// Thanh nghe thu gọn nằm trên thanh tab. Tách phần hiển thị khỏi TtsPlayer để
/// test được bố cục ở cỡ chữ lớn mà không cần engine TTS thật.
class MiniPlayerBar extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool playing;
  final bool loading;
  final VoidCallback onToggle;
  final VoidCallback onClose;
  final VoidCallback onOpen;

  const MiniPlayerBar({
    super.key,
    required this.title,
    required this.subtitle,
    required this.playing,
    required this.loading,
    required this.onToggle,
    required this.onClose,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final small = Theme.of(context).textTheme.bodySmall;
    return Material(
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 2, 4, 2),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('mini-player-toggle'),
                visualDensity: VisualDensity.compact,
                iconSize: 28,
                tooltip: playing ? 'Tạm dừng đọc' : 'Tiếp tục nghe',
                icon: loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        playing
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                      ),
                onPressed: loading ? null : onToggle,
              ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: small?.copyWith(color: scheme.outline),
                    ),
                  ],
                ),
              ),
              IconButton(
                key: const ValueKey('mini-player-close'),
                visualDensity: VisualDensity.compact,
                iconSize: 22,
                tooltip: 'Đóng trình nghe',
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Chỉ hiện khi có phiên nghe (đang phát hoặc tạm dừng). Chạm vào thân thanh
/// mở lại màn đọc đúng chương đang nghe.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.read(ttsPlayerProvider);
    return ListenableBuilder(
      listenable: player,
      builder: (context, _) {
        final c = player.chapter;
        if (c == null) return const SizedBox.shrink();
        final story = player.storyTitle?.trim() ?? '';
        return MiniPlayerBar(
          title: story.isEmpty ? 'Đang nghe' : story,
          subtitle: c.title,
          playing: player.playing,
          loading: player.loading,
          onToggle: () {
            if (player.playing) {
              player.pause();
            } else {
              player.resume();
            }
          },
          onClose: player.closeSession,
          onOpen: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ReaderScreen(
                  url: c.url,
                  storyUrl: player.readingStoryUrl,
                  storyTitle: player.storyTitle,
                ),
              ),
            );
          },
        );
      },
    );
  }
}
