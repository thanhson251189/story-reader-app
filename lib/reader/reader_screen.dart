import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/providers.dart';
import '../fetcher/web_fetcher.dart';
import '../fetcher/webview_fallback_screen.dart';
import '../tts/tts_player.dart';
import 'toc_screen.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final String url;
  const ReaderScreen({super.key, required this.url});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final _scroll = ScrollController();
  Timer? _saveTimer;
  ChapterContent? _content;
  bool _loading = true;
  String? _error;
  String? _failedUrl;
  final _settings = ReaderSettings();
  List<GlobalKey> _paraKeys = [];
  int _lastSpokenPara = -1;
  String? _shownError;
  late final TtsPlayer _player;

  static const _themes = {
    'light': (Color(0xFFFAF7F2), Color(0xFF2B2B2B)),
    'dark': (Color(0xFF121212), Color(0xFFDADADA)),
    'sepia': (Color(0xFFF4ECD8), Color(0xFF5B4636)),
  };

  @override
  void initState() {
    super.initState();
    _player = ref.read(ttsPlayerProvider);
    _player.addListener(_onPlayer);
    _scroll.addListener(_onScroll);
    _init();
  }

  Future<void> _init() async {
    final db = ref.read(appDbProvider);
    _settings.fontSize =
        double.tryParse(await db.getSetting('fontSize') ?? '') ?? 20;
    _settings.lineHeight =
        double.tryParse(await db.getSetting('lineHeight') ?? '') ?? 1.8;
    _settings.theme = await db.getSetting('readerTheme') ?? 'light';
    _settings.prefetchCount =
        (int.tryParse(await db.getSetting('prefetchCount') ?? '') ?? 3).clamp(
          1,
          5,
        );
    if (mounted) setState(() {});
    await _load(widget.url);
  }

  void _onPlayer() {
    if (!mounted) return;
    final err = _player.lastError;
    if (err != null && err != _shownError) {
      _shownError = err;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    final pc = _player.chapter;
    if (pc != null && pc.url != _content?.url && !_loading) {
      setState(() {
        _content = pc;
        _paraKeys = List.generate(pc.paragraphs.length, (_) => GlobalKey());
        _lastSpokenPara = -1;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
      return;
    }
    setState(() {});
    final idx = _player.currentParaIndex;
    if (_player.playing &&
        idx >= 0 &&
        idx != _lastSpokenPara &&
        idx < _paraKeys.length) {
      _lastSpokenPara = idx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _paraKeys[idx].currentContext;
        if (ctx != null) {
          Scrollable.ensureVisible(
            ctx,
            duration: const Duration(milliseconds: 300),
            alignment: 0.0,
          );
        }
      });
    }
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      final c = _content;
      if (_scroll.hasClients && c != null) {
        ref.read(appDbProvider).savePosition(c.url, _scroll.offset);
      }
    });
  }

  Future<void> _load(String url, {bool useCache = true}) async {
    if (_content != null && _scroll.hasClients) {
      await ref.read(appDbProvider).savePosition(_content!.url, _scroll.offset);
    }
    setState(() {
      _loading = true;
      _error = null;
      _failedUrl = url;
    });
    try {
      final db = ref.read(appDbProvider);
      ChapterContent? c;
      if (useCache) c = await db.getCachedChapter(url);
      if (c == null) {
        if (url.startsWith('book:')) {
          throw Exception('Chương này không còn trong máy. Hãy nhập lại sách.');
        }
        final adapter = ref.read(adapterRepoProvider).forUrl(url);
        if (adapter == null) {
          throw Exception(
            'Chưa có adapter cho trang này. Vào Nguồn để thêm registry.',
          );
        }
        c = await ref.read(webFetcherProvider).fetchChapter(url, adapter);
      }
      final cc = c;
      await db.cacheChapter(cc);
      await db.setSetting('lastUrl', url);
      await db.touchLibrary(storyUrlFromChapter(url), url);
      unawaited(ref.read(chapterPrefetcherProvider).prefetch(cc.nextUrl));
      final saved = await db.getPosition(url);
      if (!mounted) return;
      setState(() {
        _content = cc;
        _paraKeys = List.generate(cc.paragraphs.length, (_) => GlobalKey());
        _loading = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(
            (saved ?? 0)
                .clamp(0.0, _scroll.position.maxScrollExtent)
                .toDouble(),
          );
        }
      });
      if (_player.playing) await _player.start(c);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e is ChallengeException
            ? e.toString()
            : e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  bool _addingToLib = false;

  Future<void> _addToLibrary() async {
    final c = _content;
    if (c == null || _addingToLib) return;
    setState(() => _addingToLib = true);
    try {
      final storyUrl = storyUrlFromChapter(c.url);
      final adapter = ref.read(adapterRepoProvider).forUrl(storyUrl);
      if (adapter == null) throw Exception('Chưa có adapter cho trang này');
      final info = await ref
          .read(webFetcherProvider)
          .fetchStory(storyUrl, adapter);
      final db = ref.read(appDbProvider);
      await db.upsertLibrary(
        storyUrl: storyUrl,
        title: info.title,
        coverUrl: info.coverUrl,
        lastChapterUrl: c.url,
      );
      await db.saveToc(storyUrl, info.chapters);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Đã thêm "${info.title}" vào thư viện')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Lỗi: $e')));
    } finally {
      if (mounted) setState(() => _addingToLib = false);
    }
  }

  Future<void> _openFallback() async {
    final url = _failedUrl;
    if (url == null) return;
    final adapter = ref.read(adapterRepoProvider).forUrl(url);
    if (adapter == null) return;
    final map = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => WebViewFallbackScreen(
          url: url,
          extractJs: WebFetcher.chapterJs(adapter),
        ),
      ),
    );
    if (map == null || !mounted) return;
    final c = ChapterContent.fromJson(map);
    final cleaned = ChapterContent(
      url: c.url,
      title: c.title,
      paragraphs: c.paragraphs
          .map(adapter.clean)
          .where((p) => p.isNotEmpty)
          .toList(),
      nextUrl: c.nextUrl,
      prevUrl: c.prevUrl,
    );
    if (cleaned.paragraphs.isEmpty) {
      setState(
        () => _error =
            'WebView chưa lấy được nội dung, thử lại sau khi trang tải xong',
      );
      return;
    }
    final db = ref.read(appDbProvider);
    await db.cacheChapter(cleaned);
    await db.setSetting('lastUrl', cleaned.url);
    if (!mounted) return;
    setState(() {
      _content = cleaned;
      _paraKeys = List.generate(cleaned.paragraphs.length, (_) => GlobalKey());
      _error = null;
      _loading = false;
    });
  }

  int _visibleParaIndex() {
    if (!_scroll.hasClients) return 0;
    final offset = _scroll.offset;
    for (var i = 0; i < _paraKeys.length; i++) {
      final rb = _paraKeys[i].currentContext?.findRenderObject();
      if (rb is! RenderBox) continue;
      final viewport = RenderAbstractViewport.of(rb);
      final top = viewport.getOffsetToReveal(rb, 0.0).offset;
      if (top + rb.size.height > offset) return i;
    }
    return 0;
  }

  void _togglePlay() {
    final c = _content;
    if (c == null) return;
    final sameChapter = _player.chapter?.url == c.url;
    if (sameChapter && _player.playing) {
      _player.pause();
      return;
    }
    if (_player.voiceWarning != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(_player.voiceWarning!)));
    }
    final visible = _visibleParaIndex();
    // Đang tạm dừng và chưa cuộn khỏi đoạn đang đọc → phát tiếp mạch cũ;
    // đã cuộn tới chỗ khác → bắt đầu từ đoạn văn đang hiển thị trên màn hình.
    if (sameChapter &&
        _player.chunks.isNotEmpty &&
        visible == _player.currentParaIndex) {
      _player.resume();
    } else {
      _player.start(c, paraIndex: visible);
    }
  }

  void _sleepTimerMenu() {
    showModalBottomSheet(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Hẹn giờ tắt tiếng đọc',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            for (final m in [15, 30, 60])
              ListTile(
                leading: const Icon(Icons.timer_outlined),
                title: Text('$m phút'),
                onTap: () {
                  _player.setSleepTimer(m);
                  Navigator.pop(context);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Sẽ tạm dừng sau $m phút')),
                  );
                },
              ),
            if (_player.sleepAt != null)
              ListTile(
                leading: const Icon(Icons.timer_off),
                title: Text(
                  'Huỷ hẹn giờ (còn ${_player.remainingSleepMinutes} phút)',
                ),
                onTap: () {
                  _player.cancelSleepTimer();
                  Navigator.pop(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  static bool _isViVoice(Map<String, String> v) =>
      (v['locale'] ?? '').toLowerCase().startsWith('vi');

  String _voiceTitle(Map<String, String> v) {
    if (!_isViVoice(v)) return v['locale'] ?? (v['name'] ?? '');
    final net = v['network_required'];
    final tag = net == '1'
        ? ' · giọng mạng'
        : (net == '0' ? ' · ngoại tuyến' : '');
    return 'Tiếng Việt (${v['locale']})$tag';
  }

  String _voiceSubtitle(Map<String, String> v) {
    const q = {
      'very high': 'rất cao',
      'high': 'cao',
      'normal': 'thường',
      'low': 'thấp',
      'very low': 'rất thấp',
    };
    final quality = q[v['quality']] ?? v['quality'] ?? '';
    final net = v['network_required'] == '1'
        ? ' · cần Internet khi tạo âm thanh'
        : '';
    return '${v['name']}$net${quality.isEmpty ? '' : ' · chất lượng $quality'}';
  }

  String _currentVoiceLabel() {
    final v = _player.currentVoice;
    return v == null ? 'Mặc định của máy' : _voiceTitle(v);
  }

  void _openVoicePicker(VoidCallback onChange) {
    String? busy;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setV) {
          final vi = _player.viVoices;
          final list = vi.isNotEmpty ? vi : _player.voices;
          bool selected(Map<String, String> v) =>
              _player.currentVoice?['name'] == v['name'] &&
              _player.currentVoice?['locale'] == v['locale'];
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(
                    'Giọng đọc',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                  subtitle: Text(
                    vi.isNotEmpty
                        ? '${vi.length} giọng tiếng Việt trên máy'
                        : (list.isEmpty
                              ? 'Máy chưa trả về danh sách giọng'
                              : 'Máy chưa có giọng tiếng Việt — tạm hiện ${list.length} giọng khác'),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Tải lại danh sách',
                    onPressed: () async {
                      await _player.reloadVoices();
                      setV(() {});
                      onChange();
                    },
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    padding: EdgeInsets.only(
                      bottom: 12 + MediaQuery.of(ctx).padding.bottom,
                    ),
                    children: [
                      ListTile(
                        leading: Icon(
                          _player.currentVoice == null
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                        ),
                        title: const Text('Mặc định của máy'),
                        subtitle: const Text(
                          'Máy tự chọn giọng tiếng Việt tốt nhất',
                        ),
                        onTap: () async {
                          await _player.useDefaultVoice();
                          onChange();
                          if (ctx.mounted) Navigator.pop(ctx);
                        },
                      ),
                      for (final v in list)
                        ListTile(
                          leading: Icon(
                            selected(v)
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                          ),
                          title: Text(_voiceTitle(v)),
                          subtitle: Text(_voiceSubtitle(v)),
                          trailing: busy == v['name']
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.play_circle_outline),
                          onTap: busy != null
                              ? null
                              : () async {
                                  setV(() => busy = v['name']);
                                  final ok = await _player.selectVoice(v);
                                  onChange();
                                  if (!ok) {
                                    setV(() => busy = null);
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(
                                            const SnackBar(
                                              content: Text(
                                                'Không đổi được giọng này',
                                              ),
                                            ),
                                          );
                                    }
                                    return;
                                  }
                                  final file = await _player.previewVoice();
                                  if (!ctx.mounted) return;
                                  setV(() => busy = null);
                                  if (file == null && mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Không tạo được âm thanh thử',
                                        ),
                                      ),
                                    );
                                  }
                                },
                        ),
                    ],
                  ),
                ),
                if (vi.length == 1)
                  Padding(
                    padding: EdgeInsets.fromLTRB(
                      20,
                      8,
                      20,
                      12 + MediaQuery.of(ctx).padding.bottom,
                    ),
                    child: Text(
                      'Máy chỉ có 1 giọng tiếng Việt. Dùng Cao độ (trầm ↔ cao) để đổi chất giọng, '
                      'hoặc tải thêm giọng trong Cài đặt hệ thống → Ngôn ngữ & giọng nói → '
                      'Chuyển văn bản thành giọng nói.',
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openSettings() {
    final db = ref.read(appDbProvider);
    var previewing = false;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final titleStyle = Theme.of(ctx).textTheme.titleMedium;
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                20 + MediaQuery.of(ctx).padding.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.record_voice_over_outlined),
                    title: Text('Giọng đọc: ${_currentVoiceLabel()}'),
                    subtitle: Text(
                      _player.viVoices.isEmpty
                          ? 'Chưa lấy được danh sách giọng'
                          : '${_player.viVoices.length} giọng tiếng Việt trên máy',
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _openVoicePicker(() => setSheet(() {})),
                  ),
                  Text(
                    'Cao độ: ${_player.pitch.toStringAsFixed(1)} (trầm ↔ cao)',
                    style: titleStyle,
                  ),
                  Slider(
                    value: _player.pitch.clamp(0.5, 2.0),
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: _player.pitch.toStringAsFixed(1),
                    onChanged: (v) {
                      setSheet(() {});
                      _player.setPitch(v);
                    },
                  ),
                  Text(
                    'Tốc độ đọc: ${_player.rate.toStringAsFixed(2)}',
                    style: titleStyle,
                  ),
                  Slider(
                    value: _player.rate.clamp(0.3, 2.0),
                    min: 0.3,
                    max: 2.0,
                    divisions: 17,
                    label: _player.rate.toStringAsFixed(2),
                    onChanged: (v) {
                      setSheet(() {});
                      _player.setRate(v);
                    },
                  ),
                  FilledButton.tonalIcon(
                    onPressed: previewing
                        ? null
                        : () async {
                            setSheet(() => previewing = true);
                            final file = await _player.previewVoice();
                            if (!mounted) return;
                            setSheet(() => previewing = false);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  file == null
                                      ? 'Không tạo được âm thanh thử'
                                      : 'Đang phát thử giọng hiện tại',
                                ),
                              ),
                            );
                          },
                    icon: previewing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.volume_up),
                    label: const Text('Nghe thử'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Cỡ chữ: ${_settings.fontSize.round()}',
                    style: titleStyle,
                  ),
                  Slider(
                    value: _settings.fontSize,
                    min: 14,
                    max: 32,
                    divisions: 18,
                    label: '${_settings.fontSize.round()}',
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _settings.fontSize = v);
                      db.setSetting('fontSize', v.toString());
                    },
                  ),
                  Text(
                    'Giãn dòng: ${_settings.lineHeight.toStringAsFixed(1)}',
                    style: titleStyle,
                  ),
                  Slider(
                    value: _settings.lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    label: _settings.lineHeight.toStringAsFixed(1),
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _settings.lineHeight = v);
                      db.setSetting('lineHeight', v.toString());
                    },
                  ),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(
                        value: 'light',
                        label: Text('Sáng'),
                        icon: Icon(Icons.light_mode),
                      ),
                      ButtonSegment(
                        value: 'dark',
                        label: Text('Tối'),
                        icon: Icon(Icons.dark_mode),
                      ),
                      ButtonSegment(
                        value: 'sepia',
                        label: Text('Vàng'),
                        icon: Icon(Icons.menu_book),
                      ),
                    ],
                    selected: {_settings.theme},
                    onSelectionChanged: (s) {
                      setSheet(() {});
                      setState(() => _settings.theme = s.first);
                      db.setSetting('readerTheme', s.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Tải trước: ${_settings.prefetchCount} chương',
                    style: titleStyle,
                  ),
                  Slider(
                    value: _settings.prefetchCount.toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    label: '${_settings.prefetchCount}',
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _settings.prefetchCount = v.round());
                      db.setSetting('prefetchCount', '${v.round()}');
                    },
                  ),
                  Text(
                    'Tải nền chương kế để đọc/nghe liền mạch. Nghỉ 5s giữa các lần tải để tránh bị chặn.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _player.removeListener(_onPlayer);
    _saveTimer?.cancel();
    final c = _content;
    if (c != null && _scroll.hasClients) {
      ref.read(appDbProvider).savePosition(c.url, _scroll.offset);
    }
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _themes[_settings.theme] ?? _themes['light']!;
    final c = _content;
    final isPlayingThis = _player.playing && _player.chapter?.url == c?.url;
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        foregroundColor: fg,
        title: Text(
          c?.title ?? 'Đang tải...',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (c != null)
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => TocScreen(
                    storyUrl: storyUrlFromChapter(c.url),
                    currentChapterUrl: c.url,
                  ),
                ),
              ),
              tooltip: 'Mục lục',
            ),
          if (c != null && !c.url.startsWith('book:'))
            IconButton(
              icon: _addingToLib
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bookmark_add_outlined),
              onPressed: _addingToLib ? null : _addToLibrary,
              tooltip: 'Thêm vào thư viện',
            ),
          IconButton(
            icon: Icon(
              _player.sleepAt != null ? Icons.timer : Icons.timer_outlined,
            ),
            onPressed: _sleepTimerMenu,
            tooltip: 'Hẹn giờ tắt',
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _openSettings,
            tooltip: 'Cài đặt đọc',
          ),
        ],
      ),
      body: _buildBody(bg, fg),
      bottomNavigationBar: c == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.chevron_left),
                      color: fg,
                      iconSize: 32,
                      onPressed: c.prevUrl == null || _loading
                          ? null
                          : () => _load(c.prevUrl!),
                      tooltip: 'Chương trước',
                    ),
                    IconButton(
                      icon: Icon(
                        isPlayingThis ? Icons.pause_circle : Icons.play_circle,
                      ),
                      color: fg,
                      iconSize: 40,
                      onPressed: _loading ? null : _togglePlay,
                      tooltip: isPlayingThis ? 'Tạm dừng đọc' : 'Nghe đọc',
                    ),
                    Expanded(
                      child: Text(
                        c.title,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: fg),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.chevron_right),
                      color: fg,
                      iconSize: 32,
                      onPressed: c.nextUrl == null || _loading
                          ? null
                          : () => _load(c.nextUrl!),
                      tooltip: 'Chương sau',
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildBody(Color bg, Color fg) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: fg),
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: fg),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.tonal(
                    onPressed: () =>
                        _load(_failedUrl ?? widget.url, useCache: false),
                    child: const Text('Thử lại'),
                  ),
                  FilledButton.tonal(
                    onPressed: _openFallback,
                    child: const Text('Mở WebView'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final c = _content!;
    final style = TextStyle(
      fontSize: _settings.fontSize,
      height: _settings.lineHeight,
      color: fg,
    );
    final speakingThis = _player.playing && _player.chapter?.url == c.url;
    final activePara = speakingThis ? _player.currentParaIndex : -1;
    final chunkText = speakingThis ? (_player.currentChunk?.text ?? '') : '';
    return Scrollbar(
      controller: _scroll,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.title,
              style: style.copyWith(
                fontSize: _settings.fontSize + 4,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            for (var i = 0; i < c.paragraphs.length; i++)
              Padding(
                padding: EdgeInsets.only(bottom: _settings.fontSize * 0.7),
                child: _paragraph(
                  i,
                  c.paragraphs[i],
                  style,
                  activePara == i,
                  chunkText,
                ),
              ),
            if (c.nextUrl != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: FilledButton.icon(
                    onPressed: () => _load(c.nextUrl!),
                    icon: const Icon(Icons.arrow_forward),
                    label: const Text('Chương sau'),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _paragraph(
    int i,
    String p,
    TextStyle style,
    bool active,
    String chunkText,
  ) {
    final key = i < _paraKeys.length ? _paraKeys[i] : null;
    if (!active || chunkText.isEmpty) {
      return Text(p, key: key, style: style);
    }
    final sentences = p.split(RegExp(r'(?<=[.!?…])\s+'));
    return Text.rich(
      key: key,
      TextSpan(
        children: [
          for (final s in sentences)
            TextSpan(
              text: '$s ',
              style: chunkText.contains(s)
                  ? style.copyWith(backgroundColor: const Color(0x66FFB74D))
                  : style,
            ),
        ],
      ),
    );
  }
}
