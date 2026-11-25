import 'dart:async';

import 'package:flutter/foundation.dart';

import '../adapters/adapter_repository.dart';
import '../core/errors.dart';
import '../core/models.dart';
import '../data/app_db.dart';
import 'web_fetcher.dart';

/// Trạng thái một lượt tải cả truyện. `message` khác null nghĩa là lượt đã
/// kết thúc (xong/huỷ/lỗi) — UI hiện dòng kết quả rồi cho ẩn đi.
class StoryDownloadState {
  final String storyUrl;
  final String title;
  final int done;
  final int total;
  final String? message;

  const StoryDownloadState({
    required this.storyUrl,
    required this.title,
    required this.done,
    required this.total,
    this.message,
  });

  bool get running => message == null;

  StoryDownloadState copyWith({int? done, String? message}) =>
      StoryDownloadState(
        storyUrl: storyUrl,
        title: title,
        done: done ?? this.done,
        total: total,
        message: message,
      );
}

/// Tải lần lượt các chương còn lại của một truyện vào cache và ghim lại.
/// Chạy một lượt tại một thời điểm (trang truyện chặn khi tải dồn), có mốc
/// resume theo truyện, và luôn nghỉ giữa các lần tải thật.
class StoryDownloader {
  static final ValueNotifier<StoryDownloadState?> state = ValueNotifier(null);
  static bool _cancel = false;

  static bool get running => state.value?.running == true;

  static void cancel() => _cancel = true;

  static void dismiss() => state.value = null;

  static String resumeKey(String storyUrl) => 'storyDlResume:$storyUrl';

  /// Trả false khi đang tải truyện khác hoặc chưa có mục lục để tải.
  static Future<bool> start({
    required AppDb db,
    required WebFetcher fetcher,
    required AdapterRepository adapters,
    required String storyUrl,
    Duration gap = const Duration(seconds: 5),
  }) async {
    if (running) return false;
    final toc = await db.getToc(storyUrl);
    if (toc.isEmpty) {
      state.value = StoryDownloadState(
        storyUrl: storyUrl,
        title: '',
        done: 0,
        total: 0,
        message: 'Chưa có mục lục. Mở mục lục một lần rồi tải lại.',
      );
      return false;
    }
    String title = '';
    try {
      final lib = await db.getLibrary();
      for (final row in lib) {
        if (sameChapterUrl(row['story_url'] as String?, storyUrl)) {
          title = (row['title'] as String? ?? '').trim();
          break;
        }
      }
    } catch (_) {}
    final resume =
        int.tryParse(await db.getSetting(resumeKey(storyUrl)) ?? '') ?? 0;
    // Đã chạy xong lần trước thì lượt mới quét lại từ đầu; chương đã có chỉ
    // được ghim lại, không tải mạng lại.
    var i = (resume >= 0 && resume < toc.length) ? resume : 0;
    _cancel = false;
    state.value = StoryDownloadState(
      storyUrl: storyUrl,
      title: title,
      done: i,
      total: toc.length,
    );

    var fetched = 0;
    var fail = 0;
    var streak = 0;
    var challenges = 0;
    var pace = gap;
    String? lastErr;

    while (i < toc.length && !_cancel) {
      final url = toc[i].url;
      try {
        final cached = await db.getCachedChapter(url);
        if (cached == null) {
          final adapter = adapters.forUrl(url);
          if (adapter == null) {
            lastErr = 'chưa cài nguồn cho trang này';
            break;
          }
          if (fetched > 0 && !await _pause(pace)) break;
          final c = await fetcher.fetchChapter(url, adapter);
          await db.cacheChapter(await db.fillNav(c));
          fetched++;
        }
        await db.pinChapter(url);
        streak = 0;
        i++;
        await db.setSetting(resumeKey(storyUrl), '$i');
        state.value = state.value?.copyWith(done: i);
      } on ChallengeException {
        challenges++;
        lastErr = 'trang chặn bot';
        if (challenges >= 8) break;
        // Bị chặn theo số lượt: nghỉ dài hơn rồi thử lại đúng chương.
        pace = Duration(seconds: (pace.inSeconds + 2).clamp(5, 15).toInt());
        if (!await _pause(const Duration(seconds: 60))) break;
      } catch (e) {
        fail++;
        lastErr = friendlyError(e);
        if (++streak >= 3) break;
        i++;
        await db.setSetting(resumeKey(storyUrl), '$i');
        if (!await _pause(pace)) break;
      }
    }

    final stop = _cancel;
    _cancel = false;
    final done = state.value?.done ?? i;
    final String msg;
    if (stop) {
      msg = 'Đã dừng ở chương $done/${toc.length}';
    } else if (i >= toc.length) {
      await db.setSetting(resumeKey(storyUrl), '');
      msg = fail > 0
          ? 'Đã tải $done/${toc.length} chương, $fail lỗi: ${lastErr ?? ''}'
          : 'Đã tải xong $done/${toc.length} chương';
    } else {
      msg = done > 0
          ? 'Tạm dừng ở $done/${toc.length}: ${lastErr ?? 'lỗi mạng'}'
          : 'Không tải được: ${lastErr ?? 'lỗi mạng'}';
    }
    state.value = state.value?.copyWith(message: msg);
    return true;
  }

  static Future<bool> _pause(Duration gap) async {
    const step = Duration(milliseconds: 250);
    var left = gap;
    while (left > Duration.zero) {
      if (_cancel) return false;
      final slice = left < step ? left : step;
      await Future<void>.delayed(slice);
      left -= slice;
    }
    return !_cancel;
  }
}
