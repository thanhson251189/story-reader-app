import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../data/app_db.dart';
import '../fetcher/web_fetcher.dart';
import '../fetcher/webview_fallback_screen.dart';
import '../settings/word_fix_screen.dart';
import '../sources/source_login_screen.dart';
import '../sources/source_switch_screen.dart';
import '../sources/sources_screen.dart';
import '../tts/tts_player.dart';
import 'reader_fonts.dart';
import 'toc_screen.dart';

class ReaderScreen extends ConsumerStatefulWidget {
  final String url;
  final String? storyUrl;

  /// Tên truyện nếu nơi mở đã biết. Lưu thư viện và thẻ "Đọc tiếp" dùng tên
  /// này, không phải đường link.
  final String? storyTitle;

  /// Mở màn là nhảy thẳng tới đoạn này (từ danh sách đánh dấu đoạn).
  final int? initialParagraph;
  const ReaderScreen({
    super.key,
    required this.url,
    this.storyUrl,
    this.storyTitle,
    this.initialParagraph,
  });

  /// Đang ở chương cuối: ưu tiên vị trí trong mục lục đã lưu; chưa có mục
  /// lục thì dựa vào việc trang chương có nút chương sau hay không.
  static bool atTocEnd({
    required int? tocIndex,
    required int? tocTotal,
    required bool hasNext,
  }) {
    if (tocIndex != null && tocTotal != null) return tocIndex == tocTotal - 1;
    return !hasNext;
  }

  // "Chương 1234: Tên" / "Hồi 3 - ..." — nhóm 1 là số chương, khớp tới hết
  // dấu phân cách để lấy phần tên chương còn lại.
  static final _chapterHead = RegExp(
    r'^\s*(?:chương|chapter|hồi|tiết|quyển|phần)\s*(\d+(?:[.,]\d+)?)'
    r'\s*[:\-–—.]?\s*',
    caseSensitive: false,
  );

  /// Số chương đọc từ đầu tiêu đề ("Chương 12: ..." → 12), null nếu tiêu đề
  /// không mang số.
  static int? chapterNumberFromTitle(String title) {
    final m = _chapterHead.firstMatch(title);
    if (m == null) return null;
    return double.tryParse(m[1]!.replaceAll(',', '.'))?.floor();
  }

  /// Tên chương sau phần số ("Chương 12: Tên" → "Tên"); dòng số chương đã
  /// hiện riêng nên không lặp lại ở đây. Tiêu đề không có số thì giữ nguyên.
  static String chapterRest(String title) {
    final m = _chapterHead.firstMatch(title);
    return m == null ? title.trim() : title.substring(m.end).trim();
  }

  /// Chương kế tiếp sau [currentUrl] trong [toc], không nhảy cóc qua chương
  /// mới khác. Khớp URL đã chuẩn hóa trước; lệch URL (trang đổi link chương)
  /// thì theo số chương: chương gần nhất có số lớn hơn chương đang đọc.
  /// Không xác định được thì trả null — nơi gọi mở mục lục, không đoán bừa
  /// rồi mở chương mới nhất và bỏ qua các chương mới ở giữa.
  static ChapterRef? nextChapterAfter(String currentUrl, List<ChapterRef> toc) {
    final cur = normalizeChapterUrl(currentUrl);
    final i = toc.indexWhere((c) => normalizeChapterUrl(c.url) == cur);
    if (i >= 0) return i + 1 < toc.length ? toc[i + 1] : null;
    final n = WebFetcher.trailingNumber(currentUrl);
    if (n == null) return null;
    ChapterRef? best;
    int? bestN;
    for (final c in toc) {
      final m = WebFetcher.trailingNumber(c.url);
      if (m == null || m <= n) continue;
      if (bestN == null || m < bestN) {
        best = c;
        bestN = m;
      }
    }
    return best;
  }

  /// Bản web mới ngắn hơn nhiều so với bản đã lưu: thường là trang đăng nhập,
  /// trang chặn, hoặc trang chưa tải hết chữ. Không ghi đè bản đầy đủ.
  /// Chương vốn đã ngắn (dưới 400 chữ) thì nhận bản mới — không có gì để giữ.
  static bool shorterThanCached(ChapterContent cached, ChapterContent fresh) {
    int len(ChapterContent c) =>
        c.paragraphs.fold<int>(0, (n, p) => n + p.length);
    final oldLen = len(cached);
    if (oldLen < 400) return false;
    return len(fresh) * 2 < oldLen;
  }

  /// Đoạn đánh dấu: ưu tiên đoạn người dùng đang chạm, không phải lần đầu câu
  /// đó xuất hiện trong chương. [pressedIndex] null thì mới tìm từ đầu.
  static int? bookmarkParagraphIndex(
    List<String> paragraphs,
    String selectedText, {
    int? pressedIndex,
  }) {
    final probe = selectedText.trim().split('\n').first.trim();
    if (probe.isEmpty) return null;
    bool has(int i) =>
        i >= 0 && i < paragraphs.length && paragraphs[i].contains(probe);
    if (pressedIndex != null && has(pressedIndex)) return pressedIndex;
    final start = pressedIndex == null || pressedIndex < 0 ? 0 : pressedIndex;
    for (var i = start; i < paragraphs.length; i++) {
      if (has(i)) return i;
    }
    for (var i = 0; i < start; i++) {
      if (has(i)) return i;
    }
    return null;
  }

  /// Đoạn văn có chứa từ khoá (không phân biệt hoa thường, dấu tiếng Việt).
  /// Khoảng trắng trong từ khoá — kể cả xuống dòng của selection nhiều dòng —
  /// được dẹp như nội dung chương. Từ khoá bắt đầu hoặc kết thúc bằng chữ/số
  /// phải khớp trọn token: "Ngũ" (fold thành "ngu") không được khớp trong "người".
  static bool paragraphMatches(String text, String query) {
    final q = flattenForProbe(query).trim();
    if (q.isEmpty) return false;
    final fQuery = TocScreen.fold(q);
    if (fQuery.isEmpty) return false;
    return _nextBoundedHit(TocScreen.fold(text), fQuery, 0) >= 0;
  }

  /// plainText của selection nhiều dòng join bằng '\n', còn nội dung chương
  /// đã chuẩn hoá \s+→' ' nên KHÔNG chứa '\n' — dẹp về một hàng trước khi
  /// khớp để probe tìm đoạn chứa phần đầu/cuối selection không thất bại với
  /// selection bôi đen cả đoạn nhiều dòng (khớp đúng vì wrap luôn xảy ra tại
  /// khoảng trắng nên bản dẹp vẫn trùng với bản gốc tại vị trí nối dòng).
  static String flattenForProbe(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

  static bool _isSearchTokenChar(int unit) =>
      (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x7A);

  /// [at] là chỗ [foldedQuery] nằm trong [foldedText]. Nếu từ khoá bắt đầu hoặc
  /// kết thúc bằng chữ/số thì ký tự kề phải không phải chữ/số — nếu không,
  /// "ngu" khớp nhầm bên trong "nguoi".
  static bool _hitIsBounded(String foldedText, String foldedQuery, int at) {
    final end = at + foldedQuery.length;
    if (_isSearchTokenChar(foldedQuery.codeUnitAt(0)) &&
        at > 0 &&
        _isSearchTokenChar(foldedText.codeUnitAt(at - 1))) {
      return false;
    }
    if (_isSearchTokenChar(foldedQuery.codeUnitAt(foldedQuery.length - 1)) &&
        end < foldedText.length &&
        _isSearchTokenChar(foldedText.codeUnitAt(end))) {
      return false;
    }
    return true;
  }

  static int _nextBoundedHit(String foldedText, String foldedQuery, int from) {
    var at = foldedText.indexOf(foldedQuery, from);
    while (at >= 0) {
      if (_hitIsBounded(foldedText, foldedQuery, at)) return at;
      at = foldedText.indexOf(foldedQuery, at + 1);
    }
    return -1;
  }

  /// Tách [text] thành các TextSpan, chỗ khớp [query] (so sánh KHÔNG DẤU qua
  /// fold, trọn token như [paragraphMatches]) mang [matchStyle], phần còn lại
  /// mang [baseStyle]. fold giữ nguyên độ dài từng ký tự nên vị trí khớp trong
  /// bản fold khớp 1-1 với bản gốc.
  static List<TextSpan> highlightSpans(
    String text,
    String query,
    TextStyle base,
    TextStyle match,
  ) {
    final q = flattenForProbe(query).trim();
    if (q.isEmpty) return [TextSpan(text: text, style: base)];
    final fText = TocScreen.fold(text);
    final fQuery = TocScreen.fold(q);
    if (fQuery.isEmpty) return [TextSpan(text: text, style: base)];
    final spans = <TextSpan>[];
    var start = 0;
    var at = _nextBoundedHit(fText, fQuery, 0);
    while (at >= 0) {
      if (at > start) {
        spans.add(TextSpan(text: text.substring(start, at), style: base));
      }
      spans.add(
        TextSpan(text: text.substring(at, at + fQuery.length), style: match),
      );
      start = at + fQuery.length;
      at = _nextBoundedHit(fText, fQuery, start);
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start), style: base));
    }
    return spans;
  }

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen>
    with RouteAware, WidgetsBindingObserver {
  final _scroll = ScrollController();
  Timer? _saveTimer;
  ChapterContent? _content;
  // Bản gốc TRƯỚC khi áp sửa từ: thêm cụm từ mới lúc đang đọc (bôi đen →
  // "Đổi từ") cần áp lại từ bản gốc, không phải chồng sửa lên bản đã sửa.
  ChapterContent? _contentRaw;
  // Text đang bôi đen (onSelectionChanged của SelectionArea báo về). Menu
  // Copy/Đổi từ/Dịch/Đánh dấu của app tự vẽ trong ROOT OVERLAY theo trạng
  // thái này thay vì dùng toolbar tự động của SDK — trên máy thật selection
  // thành công nhưng toolbar của SDK có lúc không hiện, còn callback này
  // luôn chạy. Menu trong overlay đè lên được cả núm kéo selection.
  final GlobalKey<SelectionAreaState> _selectionAreaKey = GlobalKey();
  final GlobalKey _bodyStackKey = GlobalKey();
  OverlayEntry? _selectionMenuEntry;
  String? _selectedText;
  // Điểm chạm xuống (tọa độ trong body) — neo menu sát vùng chữ bôi đen.
  Offset? _pointerDownLocal;
  DateTime? _pointerDownAt;
  // Chạm vào nút (Chương sau) không được tính là chạm để ẩn thanh.
  bool _ateTap = false;
  // Thanh trên và thanh nghe. Ẩn khi đang đọc chữ; nghe thì thanh nghe giữ lại.
  bool _chromeVisible = true;
  bool _inLibrary = false;
  // Đã nhắc "truyện chưa có trong Thư viện" lần nào chưa (mỗi phiên đọc một lần).
  bool _nudgedSave = false;
  static bool _askedNotif = false;
  // Offset cuộn lúc mở menu. Menu nằm ở root overlay, không đi theo
  // SingleChildScrollView — trừ delta này thì menu đứng yên đè chữ khác khi cuộn.
  double? _menuScrollAnchor;
  // Đoạn cần nhảy tới ngay khi mở màn (từ danh sách đánh dấu đoạn).
  int? _pendingInitialPara;

  void _showSelectionMenu() {
    // onSelectionChanged gọi lại khi selection đổi (kéo núm). Giữ mốc cuộn nếu
    // menu đang mở, kẻo một callback giữa lúc cuộn reset menu về điểm chạm cũ.
    final keepAnchor = _selectionMenuEntry != null;
    _hideSelectionMenu();
    if (!keepAnchor) {
      _menuScrollAnchor = _scroll.hasClients ? _scroll.offset : 0;
    }
    _selectionMenuEntry = OverlayEntry(builder: (_) => _selectionMenuBubble());
    Overlay.of(context, rootOverlay: true).insert(_selectionMenuEntry!);
  }

  void _hideSelectionMenu() {
    _selectionMenuEntry?.remove();
    _selectionMenuEntry = null;
  }

  /// Gỡ toàn bộ trạng thái bôi đen (menu overlay + text chọn + điểm neo).
  /// Menu nằm trong ROOT OVERLAY nên KHÔNG tự gỡ theo widget tree:
  /// onSelectionChanged chỉ fire khi selection ĐỔI — route mới đẩy lên hay
  /// SelectionArea bị unmount (chương đổi) đều không fire, menu cũ treo lơ
  /// lửng trên nội dung không còn tồn tại (bug xác nhận bằng test). Nơi gọi:
  /// rời route (didPushNext), nạp chương mới, TTS tự sang chương kế.
  void _dismissSelection() {
    // Clear trước: selection vẫn còn mounted thì callback tự gỡ menu + xoá
    // text; mấy dòng sau là lưới an toàn cho trường hợp không fire được.
    _clearSelection();
    _hideSelectionMenu();
    _selectedText = null;
    _pointerDownLocal = null;
    _menuScrollAnchor = null;
  }

  bool _loading = true;
  String? _error;
  String? _failedUrl;
  double _fontSize = 20;
  double _lineHeight = 1.8;
  String _fontId = ReaderFonts.systemId;
  String _theme = 'light';
  int _prefetchCount = 3;
  bool _volPage = true;
  static const _volChannel = MethodChannel('story_reader/volume_keys');
  bool _volKeysEnabled = false;

  // Màn đọc đang mở xếp chồng lên nhau (mở chương khác qua mục lục là đè
  // thêm một màn đọc nữa). Phím âm lượng phục vụ màn đọc TRÊN CÙNG: handler
  // cấp lớp gắn một lần rồi điều phối qua đỉnh ngăn xếp, không lệ thuộc thứ
  // tự dispose giữa các màn đọc — trước đây màn đọc trên xoá handler chung
  // lúc dispose làm phím âm lượng chết hẳn ở màn đọc dưới khi quay về.
  static final List<_ReaderScreenState> _openReaders = [];

  static Future<dynamic> _onVolumeKey(MethodCall call) async {
    if (_openReaders.isEmpty) return null;
    return _openReaders.last._onNativeKey(call);
  }

  bool _isTopRoute = true;
  List<GlobalKey> _paraKeys = [];
  int _lastSpokenPara = -1;
  String? _shownError;
  // Chương đang đọc nằm ở đâu trong mục lục đã lưu: biết đang ở chương cuối
  // để hiện nút kiểm tra chương mới ngay cuối nội dung.
  int? _tocIndex;
  int? _tocTotal;
  bool _checkingNew = false;
  // Tìm trong chương: từ khoá giữ nguyên giữa các lần mở sheet; đoạn khớp khi
  // bấm kết quả được nháy sáng 2.5s để mắt bám theo chỗ cuộn tới.
  final TextEditingController _searchCtrl = TextEditingController();
  int _flashPara = -1;
  Timer? _flashTimer;
  late final TtsPlayer _player;

  static const _themes = {
    'light': (Color(0xFFFAF7F2), Color(0xFF2B2B2B)),
    'dark': (Color(0xFF121212), Color(0xFFDADADA)),
    'sepia': (Color(0xFFF4ECD8), Color(0xFF5B4636)),
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player = ref.read(ttsPlayerProvider);
    _player.addListener(_onPlayer);
    _scroll.addListener(_onScroll);
    _pendingInitialPara = widget.initialParagraph;
    _openReaders.add(this);
    if (_openReaders.length == 1) {
      _volChannel.setMethodCallHandler(_onVolumeKey);
    }
    _init();
  }

  @override
  void didChangeMetrics() {
    // Xoay màn hình / bàn phím bật tắt: menu bôi đen neo theo toạ độ cũ sẽ
    // sai chỗ — dựng lại theo toạ độ mới của body.
    _selectionMenuEntry?.markNeedsBuild();
  }

  Future<void> _init() async {
    final db = ref.read(appDbProvider);
    _fontSize = double.tryParse(await db.getSetting('fontSize') ?? '') ?? 20;
    _lineHeight =
        double.tryParse(await db.getSetting('lineHeight') ?? '') ?? 1.8;
    _fontId = ReaderFonts.byId(await db.getSetting(ReaderFonts.settingKey)).id;
    _theme = await db.getSetting('readerTheme') ?? 'light';
    _prefetchCount =
        (int.tryParse(await db.getSetting('prefetchCount') ?? '') ?? 3).clamp(
          1,
          5,
        );
    _volPage = (await db.getSetting('volPageTurn') ?? '1') == '1';
    if (mounted) setState(() {});
    _syncVolKeys();
    await _load(widget.url);
  }

  void _syncVolKeys() {
    final on = _isTopRoute && _volPage && !_player.playing;
    if (on != _volKeysEnabled) {
      _volKeysEnabled = on;
      _volChannel.invokeMethod('setEnabled', on);
    }
  }

  Future<dynamic> _onNativeKey(MethodCall call) async {
    if (call.method == 'volumeKey') {
      _scrollPage(call.arguments == 'down');
    }
    return null;
  }

  void _scrollPage(bool down) {
    if (_content == null || !_scroll.hasClients) return;
    final page = _scroll.position.viewportDimension * 0.9;
    _scroll.animateTo(
      (_scroll.offset + (down ? page : -page)).clamp(
        0.0,
        _scroll.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
    _syncVolKeys();
  }

  @override
  void didPushNext() {
    _isTopRoute = false;
    // Menu bôi đen nằm trong root overlay: không gỡ thì nó đè lên màn mới
    // (mục lục, hẹn giờ, cài đặt đọc, màn đọc mở từ bookmark chương khác).
    _dismissSelection();
    _syncVolKeys();
  }

  @override
  void didPopNext() {
    _isTopRoute = true;
    _syncVolKeys();
  }

  void _onPlayer() {
    if (!mounted) return;
    _syncVolKeys();
    final err = _player.lastError;
    if (err != null && err != _shownError) {
      _shownError = err;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err)));
    }
    final pc = _player.chapter;
    // Chỉ đi theo chương TTS khi đang phát; lúc pause, chapter cũ còn giữ lại
    // và mọi notify (hẹn giờ tắt, đổi giọng...) không được kéo reader lùi chương.
    if (_player.playing && pc != null && pc.url != _content?.url && !_loading) {
      final old = _content;
      // Chương đổi dưới chân menu bôi đen: gỡ ngay, không để menu cũ neo vào
      // text của chương vừa kết thúc.
      _dismissSelection();
      _saveTimer?.cancel();
      if (old != null && _scroll.hasClients) {
        ref.read(appDbProvider).savePosition(old.url, _scroll.offset);
      }
      setState(() {
        _content = pc;
        _contentRaw = pc;
        _paraKeys = List.generate(pc.paragraphs.length, (_) => GlobalKey());
        _flashPara = -1;
        _lastSpokenPara = -1;
      });
      unawaited(_updateProgress(pc.url));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(0);
      });
      return;
    }
    setState(() {});
    // Theo đoạn văn cả khi đã dừng: tua câu lúc pause phải cuộn tới đúng chỗ
    // để bấm phát trong app cũng đọc từ đó. Chỉ theo khi cùng chương — không
    // bao giờ kéo reader lùi về chương TTS khác.
    final idx = _player.currentParaIndex;
    if (_player.chapter?.url == _content?.url &&
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
    _selectionMenuEntry?.markNeedsBuild();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), () {
      final c = _content;
      if (_scroll.hasClients && c != null) {
        ref.read(appDbProvider).savePosition(c.url, _scroll.offset);
      }
    });
  }

  // Nơi mở đã biết URL truyện (search/library/toc) thì truyền vào; trang đơn
  // như wikisource không suy được URL truyện từ URL chương bằng cách bỏ segment.
  String _storyUrlOf(String chapterUrl) =>
      widget.storyUrl ?? storyUrlFromChapter(chapterUrl);

  Future<void> _load(String url, {bool useCache = true}) async {
    // Chương sắp đổi: gỡ menu bôi đen trước — selection cũ neo vào text cũ,
    // không gỡ thì menu treo trên chương mới (SelectionArea unmount không
    // fire onSelectionChanged).
    _dismissSelection();
    if (_content != null && _scroll.hasClients) {
      await ref.read(appDbProvider).savePosition(_content!.url, _scroll.offset);
    }
    // Mở chương khác khi đang nghe thì dừng nghe luôn — không tự động nghe
    // hộ chương vừa mở (muốn nghe chương này thì bấm Play). Mở lại đúng
    // chương đang nghe thì giữ phiên nghe tiếp tục. TTS tự sang chương kế
    // khi nghe hết chương không đi qua đây nên không bị ảnh hưởng.
    if (_player.playing && _player.chapter?.url != url) {
      await _player.stop();
    }
    setState(() {
      _loading = true;
      _error = null;
      _failedUrl = url;
    });
    try {
      final db = ref.read(appDbProvider);
      ChapterContent? c;
      var keptShorter = false;
      // true khi đã gọi web (kể cả web trả bản cụt hoặc lỗi). Mở lại bản đã
      // lưu thì false — không làm mới ngày tải, kẻo chương đọc hàng tuần không
      // bao giờ được tải lại.
      var attemptedRefresh = false;
      if (useCache) c = await db.getCachedChapter(url);
      if (c != null && !url.startsWith('book:')) {
        // Cache lâu hơn staleCacheDays coi là nội dung cũ: thử tải bản mới
        // từ web; lỗi mạng/chặn thì vẫn đọc bản cũ — đọc được chương cũ vẫn
        // tốt hơn là báo lỗi đứng hình. Bản mới ngắn hơn nhiều thì cũng giữ
        // bản cũ: trang chặn/đăng nhập vẫn có vài đoạn chữ, không được ghi đè.
        try {
          final at = await db.chapterFetchedAt(url);
          final stale =
              at == null ||
              DateTime.now().millisecondsSinceEpoch - at >
                  AppDb.staleCacheDays * Duration.millisecondsPerDay;
          if (stale) {
            final adapter = ref.read(adapterRepoProvider).forUrl(url);
            if (adapter != null) {
              attemptedRefresh = true;
              try {
                final fresh = await ref
                    .read(webFetcherProvider)
                    .fetchChapter(url, adapter);
                if (ReaderScreen.shorterThanCached(c, fresh)) {
                  keptShorter = true;
                } else {
                  c = fresh;
                }
              } catch (_) {}
            }
          }
        } catch (_) {}
      }
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
        attemptedRefresh = true;
      }
      final cc = await db.fillNav(c);
      await db.cacheChapter(cc, touchFetchedAt: attemptedRefresh);
      // Sửa từ người dùng dạy cho phần HIỂN THỊ; cache giữ bản gốc (cache
      // bản đã sửa thì xoá cụm từ trong danh sách không khôi phục được).
      final fixed = await db.fixWords(cc, storyUrl: _storyUrlOf(url));
      await db.setSetting('lastUrl', url);
      final storyName = widget.storyTitle?.trim();
      final label = (storyName != null && storyName.isNotEmpty)
          ? storyName
          : cc.title;
      if (label.isNotEmpty) await db.setSetting('lastTitle', label);
      await db.touchLibrary(_storyUrlOf(url), url);
      unawaited(ref.read(chapterPrefetcherProvider).prefetch(cc.nextUrl));
      final saved = await db.getPosition(url);
      if (!mounted) return;
      setState(() {
        _content = fixed;
        _contentRaw = cc;
        _paraKeys = List.generate(fixed.paragraphs.length, (_) => GlobalKey());
        _flashPara = -1;
        _loading = false;
      });
      unawaited(_refreshSaved());
      unawaited(_nudgeSaveIfNeeded());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // Mở từ danh sách đánh dấu: nhảy thẳng tới đoạn đã đánh dấu thay vì
        // vị trí đọc cũ. Ưu tiên cao hơn vị trí đã lưu.
        final para = _pendingInitialPara;
        _pendingInitialPara = null;
        if (para != null && para < _paraKeys.length) {
          _gotoParagraph(para);
          return;
        }
        if (_scroll.hasClients) {
          _scroll.jumpTo(
            (saved ?? 0)
                .clamp(0.0, _scroll.position.maxScrollExtent)
                .toDouble(),
          );
        }
      });
      unawaited(_updateProgress(url));
      if (keptShorter && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Trang trả về ít chữ hơn nhiều so với bản đã lưu. Giữ bản trong máy.',
            ),
            action: SnackBarAction(
              label: 'Tải lại',
              onPressed: () => _load(url, useCache: false),
            ),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
      });
    }
  }

  // Vị trí chương trong mục lục đã lưu; không có mục lục thì ẩn phần "/tổng".
  Future<void> _updateProgress(String chapterUrl) async {
    void clear() {
      if (mounted) {
        setState(() {
          _tocIndex = null;
          _tocTotal = null;
        });
      }
    }

    try {
      final toc = await ref.read(appDbProvider).getToc(_storyUrlOf(chapterUrl));
      if (toc.isEmpty) {
        clear();
        return;
      }
      final i = toc.indexWhere(
        (c) => TocScreen.normUrl(c.url) == TocScreen.normUrl(chapterUrl),
      );
      if (!mounted) return;
      setState(() {
        _tocIndex = i < 0 ? null : i;
        _tocTotal = toc.length;
      });
    } catch (_) {
      clear();
    }
  }

  /// Số chương đang đọc, đánh số như mục lục: số cuối đường dẫn (nguồn web
  /// nhét số chương vào URL), sách trong máy lấy chỉ số, cùng lắm thì đọc số
  /// ở đầu tiêu đề hoặc vị trí trong mục lục.
  int? _chapterNumber(ChapterContent c) {
    final book = BookUrl.chapterOf(c.url);
    if (book != null) return book + 1;
    return WebFetcher.trailingNumber(c.url) ??
        ReaderScreen.chapterNumberFromTitle(c.title) ??
        (_tocIndex == null ? null : _tocIndex! + 1);
  }

  /// Dòng số chương ở thanh trên/dưới: "1234/1350", không có mục lục thì chỉ
  /// "1234". Bỏ chữ "Chương" để cỡ chữ hệ thống lớn không cắt mất con số.
  String? _chapterLine(ChapterContent c) {
    final n = _chapterNumber(c);
    if (n == null) return null;
    final total = _tocTotal;
    return total != null && n <= total ? '$n/$total' : '$n';
  }

  bool get _atTocEnd {
    final c = _content;
    if (c == null) return false;
    return ReaderScreen.atTocEnd(
      tocIndex: _tocIndex,
      tocTotal: _tocTotal,
      hasNext: c.nextUrl != null,
    );
  }

  /// Kiểm tra chương mới ngay tại chương cuối: tải lại mục lục, có chương sau
  /// chương đang đọc thì mở luôn. Không đụng mốc 6 giờ của lần kiểm tra cả
  /// thư viện — lần đó quét mọi truyện nên mới được tính.
  Future<void> _checkNewChapter() async {
    final c = _content;
    if (c == null || _checkingNew) return;
    final storyUrl = _storyUrlOf(c.url);
    final adapter = ref.read(adapterRepoProvider).forUrl(storyUrl);
    if (adapter == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Chưa cài nguồn cho truyện này — vào Nguồn truyện để thêm',
          ),
        ),
      );
      return;
    }
    setState(() => _checkingNew = true);
    final db = ref.read(appDbProvider);
    try {
      final info = await ref
          .read(webFetcherProvider)
          .fetchStory(storyUrl, adapter);
      if (info.chapters.isEmpty) throw Exception('Không lấy được mục lục');
      // Bản thiếu page không được xoá mục lục đang có (quy tắc chung của app).
      final saved = await db.saveTocUnlessShorter(storyUrl, info);
      if (!saved) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Mục lục tải chưa đủ vài trang — giữ danh sách chương cũ',
            ),
          ),
        );
        return;
      }
      final last = info.chapters.last;
      await db.setLatestChapter(storyUrl, last.url, last.title);
      final toc = await db.getToc(storyUrl);
      final matched = toc.indexWhere(
        (ch) => normalizeChapterUrl(ch.url) == normalizeChapterUrl(c.url),
      );
      final next = ReaderScreen.nextChapterAfter(c.url, toc);
      final curN = WebFetcher.trailingNumber(c.url);
      final lastN = WebFetcher.trailingNumber(last.url);
      // Link lệch domain vẫn là cùng chương khi số chương trùng.
      final sameChapter = curN != null && lastN != null && curN == lastN;
      if (!mounted) return;
      if (next == null) {
        if (matched >= 0 || sameChapter) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Chưa có chương mới')));
        } else {
          // Trang đổi link chương hoặc mục lục đổi dạng: không đoán chương
          // để khỏi mở chương mới nhất và bỏ qua các chương mới ở giữa.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Đã cập nhật mục lục nhưng chưa xác định được chương kế tiếp',
              ),
              action: SnackBarAction(label: 'Mở mục lục', onPressed: _openToc),
            ),
          );
        }
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Có chương mới: ${next.title}')));
      await _load(next.url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Kiểm tra chương mới lỗi: ${friendlyError(e)}'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingNew = false);
    }
  }

  void _openToc() {
    final c = _content;
    if (c == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            TocScreen(storyUrl: _storyUrlOf(c.url), currentChapterUrl: c.url),
      ),
    );
  }

  bool _addingToLib = false;

  /// Dò truyện đang đọc trên nguồn khác rồi thay màn đọc hiện tại bằng chương
  /// đã ghép. Không đẩy thêm một màn đọc mới lên chồng: quay lại là về thư
  /// viện chứ không về bản đọc của nguồn cũ đã chết.
  Future<void> _openSourceSwitch() async {
    final c = _content;
    if (c == null || c.url.startsWith('book:')) return;
    final storyUrl = _storyUrlOf(c.url);
    var title = widget.storyTitle?.trim() ?? '';
    if (title.isEmpty) {
      try {
        final lib = await ref.read(appDbProvider).getLibrary();
        for (final r in lib) {
          if (sameChapterUrl(r['story_url'] as String?, storyUrl)) {
            title = (r['title'] as String? ?? '').trim();
            break;
          }
        }
      } catch (_) {}
    }
    if (!mounted) return;
    final result = await Navigator.push<SourceSwitchResult>(
      context,
      MaterialPageRoute(
        builder: (_) => SourceSwitchScreen(
          storyTitle: title,
          storyUrl: storyUrl,
          chapterUrl: c.url,
          chapterTitle: c.title,
        ),
      ),
    );
    if (result == null || !mounted) return;
    // Phiên nghe của truyện cũ không được tiếp tục dưới nguồn mới.
    final sessionStory = _player.readingStoryUrl;
    if (sessionStory != null && sameChapterUrl(sessionStory, storyUrl)) {
      await _player.closeSession();
      if (!mounted) return;
    }
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          url: result.chapterUrl,
          storyUrl: result.storyUrl,
          storyTitle: result.title,
        ),
      ),
    );
  }

  Future<void> _refreshSaved() async {
    final c = _content;
    if (c == null || c.url.startsWith('book:')) return;
    final saved = await ref.read(appDbProvider).isInLibrary(_storyUrlOf(c.url));
    if (mounted) setState(() => _inLibrary = saved);
  }

  /// Mở truyện từ Tìm kiếm/Khám phá mà không bấm Lưu: đọc xong quay lại
  /// thư viện không thấy truyện, tưởng mất. Nhắc một lần kèm nút Lưu ngay
  /// trong màn đọc; không tự thêm để tôn trọng ý "xem thử" của người dùng.
  Future<void> _nudgeSaveIfNeeded() async {
    if (_nudgedSave || !mounted) return;
    final c = _content;
    if (c == null || c.url.startsWith('book:')) return;
    final saved = await ref.read(appDbProvider).isInLibrary(_storyUrlOf(c.url));
    if (!mounted || saved) return;
    _nudgedSave = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Truyện chưa có trong Thư viện'),
        action: SnackBarAction(
          label: 'Lưu',
          onPressed: () => unawaited(_addToLibrary()),
        ),
      ),
    );
  }

  Future<void> _addToLibrary() async {
    final c = _content;
    if (c == null || _addingToLib) return;
    if (_inLibrary) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Đã nằm trong thư viện')));
      return;
    }
    setState(() => _addingToLib = true);
    final db = ref.read(appDbProvider);
    final storyUrl = _storyUrlOf(c.url);
    final known = widget.storyTitle?.trim();
    try {
      if (known != null && known.isNotEmpty) {
        await db.upsertLibrary(
          storyUrl: storyUrl,
          title: known,
          lastChapterUrl: c.url,
        );
        if (!mounted) return;
        setState(() => _inLibrary = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Đã thêm "$known" vào thư viện')),
        );
        return;
      }
      final adapter = ref.read(adapterRepoProvider).forUrl(storyUrl);
      if (adapter == null) throw Exception('Chưa có adapter cho trang này');
      try {
        final info = await ref
            .read(webFetcherProvider)
            .fetchStory(storyUrl, adapter);
        await db.saveStoryInfo(storyUrl, info, lastChapterUrl: c.url);
        if (!mounted) return;
        setState(() => _inLibrary = true);
        final extra = info.tocComplete
            ? ''
            : ' Mục lục chưa tải đủ, vẫn giữ được truyện.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã thêm "${info.title}" vào thư viện.$extra'),
          ),
        );
      } catch (e) {
        await db.upsertLibrary(
          storyUrl: storyUrl,
          title: c.title,
          lastChapterUrl: c.url,
        );
        if (!mounted) return;
        setState(() => _inLibrary = true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Đã lưu theo tên chương. ${friendlyError(e)}'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(friendlyError(e))));
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
    final cleaned = WebFetcher.cleanChapter(
      ChapterContent.fromJson(map),
      adapter,
    );
    if (cleaned.paragraphs.isEmpty) {
      setState(
        () => _error =
            'WebView chưa lấy được nội dung, thử lại sau khi trang tải xong',
      );
      return;
    }
    final db = ref.read(appDbProvider);
    final filled = await db.fillNav(cleaned);
    await db.cacheChapter(filled);
    // Hiển thị bản đã sửa từ (cache giữ bản gốc — xem đường _load).
    final shown = await db.fixWords(filled, storyUrl: _storyUrlOf(filled.url));
    await db.setSetting('lastUrl', filled.url);
    await db.touchLibrary(_storyUrlOf(filled.url), filled.url);
    // Mở chương khác qua WebView khi đang nghe cũng dừng nghe như đường
    // _load — không giữ phiên nghe chương cũ sau khi đã xem chương mới.
    if (_player.playing && _player.chapter?.url != filled.url) {
      await _player.stop();
    }
    if (!mounted) return;
    setState(() {
      _content = shown;
      _contentRaw = filled;
      _paraKeys = List.generate(shown.paragraphs.length, (_) => GlobalKey());
      _flashPara = -1;
      _error = null;
      _loading = false;
    });
    // Hai việc _load có mà trước đây đường WebView thiếu: nhãn "Chương x/y"
    // bị stale, và không tải trước chương kế sau khi vượt chặn thủ công.
    unawaited(_updateProgress(filled.url));
    unawaited(ref.read(chapterPrefetcherProvider).prefetch(filled.nextUrl));
    unawaited(_refreshSaved());
    unawaited(_nudgeSaveIfNeeded());
  }

  // Nguồn yêu cầu tài khoản (adapter khai báo loginUrl): hiện nút đăng nhập
  // cạnh các nút xử lý lỗi để người dùng mở WebView đăng nhập rồi thử lại.
  List<Widget>? _loginButton() {
    final url = _failedUrl ?? widget.url;
    final adapter = ref.read(adapterRepoProvider).forUrl(url);
    final loginUrl = adapter?.loginUrl;
    if (adapter == null || loginUrl == null) return null;
    return [
      FilledButton.tonal(
        onPressed: () async {
          final names = await loadAdapterNames(ref.read(appDbProvider));
          if (!mounted) return;
          await openSourceLogin(
            context,
            adapter,
            names[adapter.domain] ?? adapter.domain,
          );
        },
        child: const Text('Đăng nhập nguồn'),
      ),
    ];
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

  // Nút tua câu chỉ bấm được khi có phiên nghe (đang phát hoặc nghe dở) và
  // không đang chuyển chương.
  bool get _skipEnabled =>
      !_loading &&
      !_player.loading &&
      _player.chapter != null &&
      _player.chunks.isNotEmpty;

  Future<void> _askNotificationOnce() async {
    if (_askedNotif) return;
    _askedNotif = true;
    try {
      final status = await Permission.notification.status;
      if (status.isGranted) return;
      final next = await Permission.notification.request();
      if (!next.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Chưa có quyền thông báo. Nghe vẫn chạy, nhưng nút tạm dừng trên màn khóa có thể không hiện.',
            ),
            action: SnackBarAction(
              label: 'Mở cài đặt',
              onPressed: () {
                openAppSettings();
              },
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Không xin được quyền thông báo: ${friendlyError(e)}',
            ),
          ),
        );
      }
    }
  }

  void _togglePlay() {
    final c = _content;
    if (c == null) return;
    if (_player.chapter?.url == c.url && _player.playing) {
      _player.pause();
      return;
    }
    final para = _visibleParaIndex();
    final story = _storyUrlOf(c.url);
    unawaited(() async {
      await _askNotificationOnce();
      if (!mounted) return;
      if (_player.voiceWarning != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_player.voiceWarning!)));
      }
      // Luôn phát từ đầu đoạn văn đang hiển thị; nghe dở rồi dừng thì đọc lại
      // từ đầu đoạn đó (resume() cũng theo semantics này cho nút media/headset).
      _player.start(
        c,
        paraIndex: para,
        storyUrl: story,
        storyTitle: widget.storyTitle,
      );
    }());
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

  // Tìm từ khoá trong chương đang đọc: sheet liệt kê các đoạn khớp, bấm thì
  // cuộn tới và nháy sáng đoạn đó. Tìm không dấu (dùng fold chung với mục lục).
  void _openSearch() {
    final c = _content;
    if (c == null) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final q = _searchCtrl.text;
          final hits = [
            for (var i = 0; i < c.paragraphs.length; i++)
              if (ReaderScreen.paragraphMatches(c.paragraphs[i], q)) i,
          ];
          // Kết quả tìm dùng cùng font chương: không thì đoạn khớp (style
          // riêng, không kế thừa) nhảy về font máy giữa câu.
          final readFamily = ReaderFonts.familyOf(_fontId);
          final hitBase =
              (Theme.of(ctx).textTheme.bodyLarge ?? const TextStyle()).copyWith(
                fontFamily: readFamily,
              );
          final hitMatch = TextStyle(
            backgroundColor: const Color(0x66FFB74D),
            fontWeight: FontWeight.w600,
            fontFamily: readFamily,
          );
          // Nhích sheet lên TRÊN bàn phím: không có dòng này thì sheet nằm
          // dưới keyboard — lúc mới mở sheet chỉ có ô nhập (chưa có kết quả
          // nên gập gọn) là bị bàn phím trùm hết, nhìn như không hiện gì;
          // gõ chữ có kết quả thì sheet giãn cao mới ló ra (bug đã gặp).
          final insets = MediaQuery.of(ctx).viewInsets.bottom;
          return Padding(
            padding: EdgeInsets.only(bottom: insets),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: (MediaQuery.of(ctx).size.height * 0.8 - insets)
                    .clamp(220.0, MediaQuery.of(ctx).size.height * 0.8),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      onChanged: (_) => setSheet(() {}),
                      decoration: InputDecoration(
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 20),
                        hintText: 'Tìm trong chương',
                        suffixIcon: q.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close, size: 18),
                                tooltip: 'Xoá từ khoá',
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setSheet(() {});
                                },
                              ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        q.trim().isEmpty
                            ? 'Nhập từ khoá để tìm trong chương'
                            : '${hits.length} đoạn khớp',
                        style: Theme.of(ctx).textTheme.bodySmall,
                      ),
                    ),
                  ),
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.only(
                        bottom: 12 + MediaQuery.of(ctx).padding.bottom,
                      ),
                      children: [
                        if (q.trim().isNotEmpty && hits.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(16),
                            child: Text('Không tìm thấy "$q" trong chương'),
                          ),
                        for (final i in hits)
                          ListTile(
                            dense: true,
                            // Tô nền phần khớp từ khoá để mắt bắt ngay chỗ
                            // giống nhau giữa các kết quả.
                            title: Text.rich(
                              TextSpan(
                                children: ReaderScreen.highlightSpans(
                                  c.paragraphs[i],
                                  q,
                                  hitBase,
                                  hitMatch,
                                ),
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text('Đoạn ${i + 1}'),
                            onTap: () {
                              Navigator.pop(ctx);
                              // Kết quả tính trên chương lúc mở sheet: nếu
                              // nghe đọc đã tự sang chương kế trong lúc sheet
                              // mở thì index cũ áp vào chương mới là nhảy
                              // sai đoạn — chỉ nhảy khi còn đúng chương.
                              if (_content?.url == c.url) _gotoParagraph(i);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _gotoParagraph(int i) {
    if (!mounted) return;
    setState(() => _flashPara = i);
    _flashTimer?.cancel();
    _flashTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted) setState(() => _flashPara = -1);
    });
    final ctx = i < _paraKeys.length ? _paraKeys[i].currentContext : null;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 300),
        alignment: 0.0,
      );
    }
  }

  String _voiceTitle(Map<String, String> v) {
    if (!TtsPlayer.isViVoice(v)) return v['locale'] ?? (v['name'] ?? '');
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
                      // Sheet có thể đã đóng trong lúc chờ engine trả giọng.
                      if (!ctx.mounted) return;
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
                                    // Sheet có thể đã đóng trong lúc chờ
                                    // engine đổi giọng — setV lúc đó là lỗi.
                                    if (!ctx.mounted) return;
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
    var cacheLoaded = false;
    var cacheCount = 0;
    var pinnedCount = 0;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheet) {
          final titleStyle = Theme.of(ctx).textTheme.titleMedium;
          if (!cacheLoaded) {
            cacheLoaded = true;
            db.webCacheCount().then((n) {
              cacheCount = n;
              if (ctx.mounted) setSheet(() {});
            });
            db.pinnedWebCount().then((n) {
              pinnedCount = n;
              if (ctx.mounted) setSheet(() {});
            });
          }
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
                            // Synth mất vài giây: sheet có thể đã đóng giữa
                            // chừng — setSheet trên StatefulBuilder đã dispose
                            // là lỗi (giống bug dialog đã sửa ở 1.0.35).
                            if (!ctx.mounted) return;
                            setSheet(() => previewing = false);
                            ScaffoldMessenger.of(ctx).showSnackBar(
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
                  ReaderFontPicker(
                    fontId: _fontId,
                    onSelected: (font) {
                      setSheet(() {});
                      setState(() => _fontId = font.id);
                      db.setSetting(ReaderFonts.settingKey, font.id);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('Cỡ chữ: ${_fontSize.round()}', style: titleStyle),
                  Slider(
                    value: _fontSize,
                    min: 14,
                    max: 32,
                    divisions: 18,
                    label: '${_fontSize.round()}',
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _fontSize = v);
                      db.setSetting('fontSize', v.toString());
                    },
                  ),
                  Text(
                    'Giãn dòng: ${_lineHeight.toStringAsFixed(1)}',
                    style: titleStyle,
                  ),
                  Slider(
                    value: _lineHeight,
                    min: 1.2,
                    max: 2.4,
                    divisions: 12,
                    label: _lineHeight.toStringAsFixed(1),
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _lineHeight = v);
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
                    selected: {_theme},
                    onSelectionChanged: (s) {
                      setSheet(() {});
                      setState(() => _theme = s.first);
                      db.setSetting('readerTheme', s.first);
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('Tải trước: $_prefetchCount chương', style: titleStyle),
                  Slider(
                    value: _prefetchCount.toDouble(),
                    min: 1,
                    max: 5,
                    divisions: 4,
                    label: '$_prefetchCount',
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _prefetchCount = v.round());
                      db.setSetting('prefetchCount', '${v.round()}');
                    },
                  ),
                  Text(
                    'Tải nền chương kế để đọc/nghe liền mạch. Nghỉ 5s giữa các lần tải để tránh bị chặn.',
                    style: Theme.of(ctx).textTheme.bodySmall,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.cleaning_services_outlined),
                    title: Text(
                      'Dữ liệu tải sẵn: $cacheCount chương'
                      '${pinnedCount > 0 ? ' ($pinnedCount đã ghim)' : ''}',
                    ),
                    subtitle: const Text(
                      'Bản lưu chương web để đọc lại nhanh, không cần mạng. '
                      'Giữ tối đa 500 chương mới nhất; chương đã tải trước và '
                      'sách trong máy không bị xoá.',
                    ),
                    trailing: TextButton(
                      onPressed: cacheCount - pinnedCount <= 0
                          ? null
                          : () async {
                              final removable = cacheCount - pinnedCount;
                              final ok = await showDialog<bool>(
                                context: context,
                                builder: (dlg) => AlertDialog(
                                  title: const Text('Xoá dữ liệu tải sẵn?'),
                                  content: Text(
                                    'Xoá $removable chương web đã lưu. Chương '
                                    'đã tải trước (ghim) và sách nhập từ file '
                                    'không bị đụng tới.',
                                  ),
                                  actions: [
                                    TextButton(
                                      onPressed: () =>
                                          Navigator.pop(dlg, false),
                                      child: const Text('Huỷ'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(dlg, true),
                                      child: const Text('Xoá'),
                                    ),
                                  ],
                                ),
                              );
                              if (ok != true) return;
                              await db.clearWebCache();
                              cacheCount = pinnedCount;
                              if (ctx.mounted) setSheet(() {});
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      'Đã xoá dữ liệu tải sẵn'
                                      '${pinnedCount > 0 ? ', giữ $pinnedCount chương đã ghim' : ''}',
                                    ),
                                  ),
                                );
                              }
                            },
                      child: const Text('Xoá'),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.swap_vert),
                    title: const Text('Phím âm lượng lật trang'),
                    subtitle: const Text(
                      'Đang nghe đọc thì phím âm lượng chỉnh tiếng như thường.',
                    ),
                    value: _volPage,
                    onChanged: (v) {
                      setSheet(() {});
                      setState(() => _volPage = v);
                      db.setSetting('volPageTurn', v ? '1' : '0');
                      _syncVolKeys();
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.brightness_high),
                    title: const Text('Giữ màn hình sáng khi nghe đọc'),
                    subtitle: const Text(
                      'Tắt để tiết kiệm pin — âm thanh vẫn chạy nền như nghe nhạc.',
                    ),
                    value: _player.keepScreenOn,
                    onChanged: (v) {
                      setSheet(() {});
                      _player.setKeepScreenOn(v);
                    },
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
    WidgetsBinding.instance.removeObserver(this);
    _hideSelectionMenu();
    routeObserver.unsubscribe(this);
    _openReaders.remove(this);
    if (_openReaders.isEmpty) {
      _volChannel.setMethodCallHandler(null);
      _volChannel.invokeMethod('setEnabled', false);
    } else {
      // Màn đọc trên vừa bị gỡ: màn đọc dưới thành màn trên cùng — đồng bộ
      // lại cờ phím âm lượng theo trạng thái của nó (didPopNext có thể đã
      // chạy trước hoặc sau dispose, thứ tự nào cũng đúng).
      _openReaders.last._syncVolKeys();
    }
    _player.removeListener(_onPlayer);
    _saveTimer?.cancel();
    _flashTimer?.cancel();
    _searchCtrl.dispose();
    final c = _content;
    if (c != null && _scroll.hasClients) {
      ref.read(appDbProvider).savePosition(c.url, _scroll.offset);
    }
    _scroll.dispose();
    super.dispose();
  }

  // Vuốt ngang để sang chương trước/sau như các app đọc truyện thông dụng.
  // Cuộn dọc không đụng độ: SingleChildScrollView chỉ nhận cử chỉ dọc.
  void _onHorizontalDragEnd(DragEndDetails d) {
    final v = d.primaryVelocity ?? 0;
    final c = _content;
    if (c == null || _loading) return;
    if (v < -500) {
      if (c.nextUrl != null) _load(c.nextUrl!);
    } else if (v > 500) {
      if (c.prevUrl != null) _load(c.prevUrl!);
    }
  }

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _themes[_theme] ?? _themes['light']!;
    final c = _content;
    final chapterLine = c == null ? null : _chapterLine(c);
    final chapterName =
        c == null ? '' : ReaderScreen.chapterRest(c.title);
    final isPlayingThis = _player.playing && _player.chapter?.url == c?.url;
    final showBottom = c != null && (_chromeVisible || isPlayingThis);
    return Scaffold(
      backgroundColor: bg,
      appBar: !_chromeVisible
          ? null
          : AppBar(
              backgroundColor: bg,
              foregroundColor: fg,
              // Hai dòng: số chương đứng trước để không bị cắt mất, tên
              // chương theo sau. Chặn cỡ chữ ở mức 1.6 cho vừa chiều cao
              // thanh tiêu đề cố định.
              title: c == null
                  ? Text(
                      _error != null ? 'Không mở được chương' : 'Đang tải...',
                    )
                  : MediaQuery.withClampedTextScaling(
                      maxScaleFactor: 1.6,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (chapterLine != null)
                            Text(
                              chapterLine,
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          Text(
                            chapterName.isEmpty ? c.title : chapterName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
              actions: [
                if (c != null)
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: _loading ? null : _openSearch,
                    tooltip: 'Tìm trong chương',
                  ),
                if (c != null)
                  IconButton(
                    icon: const Icon(Icons.list),
                    onPressed: _openToc,
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
                        : Icon(
                            _inLibrary
                                ? Icons.bookmark
                                : Icons.bookmark_add_outlined,
                          ),
                    onPressed: _addingToLib ? null : _addToLibrary,
                    tooltip: _inLibrary
                        ? 'Đã trong thư viện'
                        : 'Thêm vào thư viện',
                  ),
                PopupMenuButton<String>(
                  tooltip: _player.sleepAt != null
                      ? 'Hẹn giờ đang chạy'
                      : 'Tuỳ chọn',
                  icon: Icon(
                    _player.sleepAt != null ? Icons.timer : Icons.more_vert,
                  ),
                  onSelected: (v) {
                    if (v == 'marks') _openBookmarks();
                    if (v == 'timer') _sleepTimerMenu();
                    if (v == 'settings') _openSettings();
                    if (v == 'switch') unawaited(_openSourceSwitch());
                  },
                  itemBuilder: (_) => [
                    if (c != null)
                      const PopupMenuItem(
                        value: 'marks',
                        child: Text('Đoạn đã đánh dấu'),
                      ),
                    if (c != null && !c.url.startsWith('book:'))
                      const PopupMenuItem(
                        value: 'switch',
                        child: Text('Tìm truyện ở nguồn khác'),
                      ),
                    PopupMenuItem(
                      value: 'timer',
                      child: Text(
                        _player.sleepAt != null
                            ? 'Hẹn giờ tắt (đang chạy)'
                            : 'Hẹn giờ tắt',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('Cài đặt đọc'),
                    ),
                  ],
                ),
              ],
            ),
      body: SafeArea(
        top: !_chromeVisible,
        bottom: !showBottom,
        child: Stack(
          fit: StackFit.expand,
          key: _bodyStackKey,
          children: [
            // Listener bị động: ghi điểm chạm để neo menu bôi đen, và nhận
            // chạm ngắn (không phải giữ để chọn chữ, không phải vuốt) để ẩn
            // thanh trên / thanh nghe.
            Listener(
              onPointerDown: (e) {
                _pointerDownLocal = e.localPosition;
                _pointerDownAt = DateTime.now();
              },
              onPointerUp: (e) {
                final down = _pointerDownLocal;
                final at = _pointerDownAt;
                if (down == null || at == null || _content == null) return;
                final moved = (e.localPosition - down).distance;
                final held = DateTime.now().difference(at);
                if (moved > 24 || held > const Duration(milliseconds: 350)) {
                  return;
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted ||
                      _ateTap ||
                      _selectedText != null ||
                      _selectionMenuEntry != null) {
                    _ateTap = false;
                    return;
                  }
                  setState(() => _chromeVisible = !_chromeVisible);
                });
              },
              child: _buildBody(bg, fg),
            ),
          ],
        ),
      ),
      bottomNavigationBar: !showBottom
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                // Chỉ nút điều khiển: số chương + tên đã ở thanh trên, không
                // lặp lại ở đây (cỡ chữ 1,6 hai thanh hiện cùng lúc).
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
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
                      icon: const Icon(Icons.fast_rewind),
                      color: fg,
                      iconSize: 26,
                      onPressed: _skipEnabled ? _player.skipPrev : null,
                      tooltip: 'Câu trước',
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
                    IconButton(
                      icon: const Icon(Icons.fast_forward),
                      color: fg,
                      iconSize: 26,
                      onPressed: _skipEnabled ? _player.skipNext : null,
                      tooltip: 'Câu sau',
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
      final failed = _failedUrl ?? widget.url;
      final adapter = ref.read(adapterRepoProvider).forUrl(failed);
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
                runSpacing: 8,
                children: [
                  FilledButton.tonal(
                    onPressed: () =>
                        _load(_failedUrl ?? widget.url, useCache: false),
                    child: const Text('Thử lại'),
                  ),
                  // Chưa cài nguồn cho trang này: "Mở WebView" không có gì để
                  // bóc (bấm vào im lặng), đưa thẳng sang màn cài nguồn.
                  if (adapter != null)
                    FilledButton.tonal(
                      onPressed: _openFallback,
                      child: const Text('Mở WebView'),
                    )
                  else
                    FilledButton.tonal(
                      // Cài xong nguồn ở màn đó thì quay lại thử mở luôn,
                      // khỏi bắt bấm Thử lại thêm lần nữa.
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SourcesScreen(),
                        ),
                      ).then((_) {
                        if (mounted) _load(failed, useCache: false);
                      }),
                      child: const Text('Mở Nguồn truyện'),
                    ),
                  ...?_loginButton(),
                ],
              ),
            ],
          ),
        ),
      );
    }
    final c = _content!;
    final style = TextStyle(
      fontFamily: ReaderFonts.familyOf(_fontId),
      fontSize: _fontSize,
      height: _lineHeight,
      color: fg,
    );
    final speakingThis = _player.playing && _player.chapter?.url == c.url;
    final activePara = speakingThis ? _player.currentParaIndex : -1;
    final chunkText = speakingThis ? (_player.currentChunk?.text ?? '') : '';
    return GestureDetector(
      onHorizontalDragEnd: _onHorizontalDragEnd,
      child: Scrollbar(
        controller: _scroll,
        child: SingleChildScrollView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          // Bôi đen được chữ khi đọc (long-press/kéo): menu Copy, Đổi từ
          // (thêm vào danh sách sửa lỗi), Dịch (Google Translate). Chỉ có
          // kéo ngang để chuyển chương nên không giành gesture với chọn text.
          child: SelectionArea(
            key: _selectionAreaKey,
            // Tắt toolbar mặc định của SDK (menu hệ thống) — hành động chạy
            // qua menu dọc riêng của app cạnh chỗ bôi đen.
            contextMenuBuilder: (_, _) => const SizedBox.shrink(),
            onSelectionChanged: (sel) {
              _selectedText = (sel == null || sel.plainText.isEmpty)
                  ? null
                  : sel.plainText;
              if (_selectedText != null) {
                _showSelectionMenu();
              } else {
                _hideSelectionMenu();
                _menuScrollAnchor = null;
              }
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  c.title,
                  style: style.copyWith(
                    fontSize: _fontSize + 4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                for (var i = 0; i < c.paragraphs.length; i++)
                  Padding(
                    padding: EdgeInsets.only(bottom: _fontSize * 0.7),
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
                        onPressed: () {
                          _ateTap = true;
                          _load(c.nextUrl!);
                        },
                        icon: const Icon(Icons.arrow_forward),
                        label: const Text('Chương sau'),
                      ),
                    ),
                  ),
                if (!c.url.startsWith('book:') && _atTocEnd)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Column(
                        children: [
                          Text(
                            'Đã hết chương đang có',
                            style: TextStyle(color: fg, fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _checkingNew
                                ? null
                                : () {
                                    _ateTap = true;
                                    _checkNewChapter();
                                  },
                            icon: _checkingNew
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.new_releases_outlined),
                            label: Text(
                              _checkingNew
                                  ? 'Đang kiểm tra...'
                                  : 'Kiểm tra chương mới',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Bôi đen text khi đọc: menu dọc Copy / Đổi từ / Dịch / Đánh dấu ----

  /// Vị trí thanh lệnh: menu NGANG nằm sát HỘP của vùng chữ bôi đen (tính
  /// từ đoạn chứa dòng đầu tới đoạn chứa dòng cuối của text chọn — selection
  /// nhiều dòng thì hộp phủ hết các dòng). Chọn ở nửa trên body thì menu nằm
  /// ngay DƯỚI hộp, nửa dưới thì nằm ngay TRÊN (như các app đọc truyện mẫu).
  /// Menu nằm trong root overlay nên đè được lên núm kéo selection, không
  /// bị núm ăn cú bấm. Tra không ra hộp (selection lạ) thì dùng điểm chạm.
  ({Offset origin, bool below, double caretDx, double width})? _menuLayout() {
    const menuH = 54.0;
    final bodyBox =
        _bodyStackKey.currentContext?.findRenderObject() as RenderBox?;
    final bodyOrigin = bodyBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    final bodySize = bodyBox?.size ?? MediaQuery.of(context).size;
    final bodyBottom = bodyOrigin.dy + bodySize.height;

    // Hộp vùng chọn: selection NGẮN (1-2 dòng) thì neo quanh dòng chạm;
    // selection DÀI (>60 ký tự — phủ nhiều dòng/nhiều đoạn như bôi đen cả
    // đoạn) thì tính hộp từ đoạn chứa phần đầu tới đoạn chứa phần cuối của
    // text chọn — menu phải nằm ngoài toàn bộ hộp, không cắm giữa các dòng
    // đã bôi đen (bug user chụp màn: menu nằm giữa selection 5 dòng).
    final p = bodyOrigin + (_pointerDownLocal ?? Offset.zero);
    var selTop = p.dy - 20;
    var selBottom = p.dy + 20;
    final sel = (_selectedText ?? '').trim();
    var liveBox = false;
    if (sel.length > 60) {
      final probeStart = ReaderScreen.flattenForProbe(sel.substring(0, 40));
      final probeEnd = ReaderScreen.flattenForProbe(
        sel.substring(sel.length - 40),
      );
      int? first;
      int? last;
      final c = _content;
      if (c != null) {
        for (var i = 0; i < c.paragraphs.length; i++) {
          final para = c.paragraphs[i];
          if (first == null && para.contains(probeStart)) first = i;
          if (para.contains(probeEnd)) last = i;
        }
      }
      if (first != null && last != null && first <= last) {
        final startBox =
            _paraKeys[first].currentContext?.findRenderObject() as RenderBox?;
        final endBox =
            _paraKeys[last].currentContext?.findRenderObject() as RenderBox?;
        if (startBox != null && endBox != null) {
          selTop = startBox.localToGlobal(Offset.zero).dy;
          selBottom = endBox.localToGlobal(Offset.zero).dy + endBox.size.height;
          liveBox = true;
        }
      }
    }
    // Selection ngắn neo điểm chạm (không đổi khi cuộn). Hộp dài dùng
    // RenderBox đang sống — đã ăn offset, không trừ delta lần nữa.
    if (!liveBox && _menuScrollAnchor != null && _scroll.hasClients) {
      final delta = _scroll.offset - _menuScrollAnchor!;
      selTop -= delta;
      selBottom -= delta;
    }
    // Chữ đã ra khỏi body: không kẹp menu vào mép, kẻo đè lên đoạn khác.
    if (selBottom < bodyOrigin.dy || selTop > bodyBottom) return null;

    final menuW = (bodySize.width - 16).clamp(0.0, 356.0);
    final selMid = (selTop + selBottom) / 2;
    final below = selMid < bodyOrigin.dy + bodySize.height / 2;
    var y = below ? selBottom + 32 : selTop - menuH - 14;
    if (below && y + menuH > bodyBottom - 8) y = selTop - menuH - 14;
    if (!below && y < bodyOrigin.dy + 8) y = selBottom + 32;
    y = y.clamp(
      bodyOrigin.dy + 8,
      (bodyBottom - menuH - 8).clamp(bodyOrigin.dy + 8, double.infinity),
    );
    // Ngang: căn giữa theo điểm chạm (chữ bôi đen thường quanh điểm đó).
    final pressX =
        bodyOrigin.dx + (_pointerDownLocal?.dx ?? bodySize.width / 2);
    var x = pressX - menuW / 2;
    x = x.clamp(
      bodyOrigin.dx + 8,
      (bodyOrigin.dx + bodySize.width - menuW - 8).clamp(
        bodyOrigin.dx + 8,
        double.infinity,
      ),
    );
    final caretDx = (pressX - x - 6.5).clamp(10.0, menuW - 24.0);
    return (origin: Offset(x, y), below: below, caretDx: caretDx, width: menuW);
  }

  /// Mũi tên nhỏ của menu hướng về vùng chữ đang bôi đen.
  Widget _menuCaret(double dx, bool below) {
    return Positioned(
      left: dx,
      top: below ? -5.5 : null,
      bottom: below ? null : -5.5,
      child: Transform.rotate(
        angle: math.pi / 4,
        child: Container(
          width: 13,
          height: 13,
          color: Theme.of(context).colorScheme.primaryContainer,
        ),
      ),
    );
  }

  Widget _selectionMenuBubble() {
    final layout = _menuLayout();
    if (layout == null) return const SizedBox.shrink();
    return Positioned(
      left: layout.origin.dx,
      top: layout.origin.dy,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Material(
            key: const Key('selection_menu'),
            color: Theme.of(context).colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
            elevation: 6,
            child: SizedBox(
              width: layout.width,
              child: Row(
                children: [
                  _menuButton(Icons.copy_all, 'Copy', _copySelected),
                  _menuButton(Icons.edit_note, 'Đổi từ', _fixSelected),
                  _menuButton(Icons.search, 'Tìm kiếm', _searchSelected),
                  _menuButton(Icons.translate, 'Dịch', _translateSelected),
                  _menuButton(
                    Icons.bookmark_add_outlined,
                    'Đánh dấu',
                    _bookmarkSelected,
                  ),
                ],
              ),
            ),
          ),
          _menuCaret(layout.caretDx, layout.below),
        ],
      ),
    );
  }

  Widget _menuButton(IconData icon, String label, VoidCallback onTap) {
    // onTapDown thay vì onTap: menu có thể bị gỡ ngay giữa cú chạm (bấm vào
    // menu cũng bị SelectionArea coi là "chạm ngoài vùng chọn" và xoá selection
    // → unmount menu) — nếu chờ tap-up thì hành động bị nuốt mất.
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => onTap(),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18),
              const SizedBox(height: 2),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.clip,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _clearSelection() =>
      _selectionAreaKey.currentState?.selectableRegion.clearSelection();

  Future<void> _copySelected() async {
    final text = (_selectedText ?? '').trim();
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Đã copy vào clipboard')));
  }

  /// Đổi từ: thêm vào danh sách sửa lỗi với cụm từ đang bôi đen, lưu xong áp
  /// lại bản sửa NGAY cho chương đang mở (không phải mở lại chương).
  Future<void> _fixSelected() async {
    final text = (_selectedText ?? '').trim();
    _clearSelection();
    if (text.isEmpty || !mounted) return;
    final db = ref.read(appDbProvider);
    final raw = _contentRaw;
    final storyUrl = raw == null ? null : _storyUrlOf(raw.url);
    final ok = await showWordFixEditor(
      context,
      db,
      initialWrong: text,
      storyChoice: storyUrl,
    );
    if (!ok || !mounted || raw == null) return;
    final fixed = await db.fixWords(raw, storyUrl: storyUrl);
    if (!mounted) return;
    setState(() {
      _content = fixed;
      _paraKeys = List.generate(fixed.paragraphs.length, (_) => GlobalKey());
      _flashPara = -1;
    });
  }

  /// Tìm kiếm: mở sheet tìm trong chương với từ khoá là text đang bôi đen —
  /// danh sách kết quả hiện luôn kèm phần khớp được tô màu.
  Future<void> _searchSelected() async {
    // plainText nhiều dòng join bằng '\n'; chương đã dẹp \s+ thành ' '.
    // Không dẹp thì từ khoá không khớp đoạn, và ô tìm hiện cả xuống dòng.
    final text = ReaderScreen.flattenForProbe(_selectedText ?? '').trim();
    _clearSelection();
    if (text.isEmpty || !mounted) return;
    _searchCtrl.text = text;
    _searchCtrl.selection = TextSelection.collapsed(offset: text.length);
    _openSearch();
  }

  /// Dịch: copy text đang bôi đen vào clipboard rồi mở Google Translate
  /// (trình duyệt ngoài) — text sẵn sàng dán vào bất kỳ công cụ dịch nào.
  Future<void> _translateSelected() async {
    final text = (_selectedText ?? '').trim();
    _clearSelection();
    if (text.isEmpty || !mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    try {
      await launchUrl(
        Uri.parse(
          'https://translate.google.com/'
          '?text=${Uri.encodeQueryComponent(text)}&op=translate',
        ),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Không mở được trình dịch: ${friendlyError(e)}'),
          ),
        );
      }
    }
  }

  /// Đoạn dưới ngón tay lúc bôi đen. Chọn câu trùng với đoạn trước đó thì
  /// đánh dấu đúng chỗ đang chạm, không nhảy lên lần xuất hiện đầu tiên.
  int? _pressedParagraphIndex() {
    final local = _pointerDownLocal;
    final body = _bodyStackKey.currentContext?.findRenderObject() as RenderBox?;
    if (local == null || body == null || !body.hasSize) return null;
    final global = body.localToGlobal(local);
    for (var i = 0; i < _paraKeys.length; i++) {
      final box = _paraKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (rect.inflate(8).contains(global)) return i;
    }
    return null;
  }

  /// Đánh dấu đoạn chứa text đang bôi đen (toggle: đã đánh dấu thì bỏ).
  Future<void> _bookmarkSelected() async {
    final sel = (_selectedText ?? '').trim();
    _clearSelection();
    final c = _content;
    if (sel.isEmpty || c == null || !mounted) return;
    final idx = ReaderScreen.bookmarkParagraphIndex(
      c.paragraphs,
      sel,
      pressedIndex: _pressedParagraphIndex(),
    );
    if (idx == null || !mounted) return;
    final para = c.paragraphs[idx];
    final added = await ref
        .read(appDbProvider)
        .toggleBookmark(
          storyUrl: _storyUrlOf(c.url),
          chapterUrl: c.url,
          chapterTitle: c.title,
          paraIndex: idx,
          snippet: para.length > 140 ? '${para.substring(0, 140)}…' : para,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added
              ? 'Đã đánh dấu đoạn ${idx + 1}'
              : 'Đã bỏ đánh dấu đoạn ${idx + 1}',
        ),
      ),
    );
  }

  /// Danh sách đánh dấu của truyện đang đọc: bấm dòng để nhảy tới đoạn, nút
  /// xoá để bỏ đánh dấu.
  Future<void> _openBookmarks() async {
    final c = _content;
    if (c == null || !mounted) return;
    final storyUrl = _storyUrlOf(c.url);
    final db = ref.read(appDbProvider);
    final items = await db.getBookmarks(storyUrl);
    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) {
          return SafeArea(
            child: ListView(
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    'Đoạn đã đánh dấu',
                    style: Theme.of(ctx).textTheme.titleMedium,
                  ),
                ),
                if (items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Chưa có đoạn nào được đánh dấu. Bôi đen chữ khi đọc '
                      'rồi bấm "Đánh dấu" để lưu đoạn cần quay lại.',
                    ),
                  ),
                for (final b in items)
                  ListTile(
                    dense: true,
                    title: Text(
                      b['snippet'] as String? ?? '',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${b['chapter_title'] as String? ?? ''} · '
                      'Đoạn ${(b['para_index'] as int? ?? 0) + 1}',
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Xoá đánh dấu',
                      onPressed: () async {
                        await db.removeBookmark(b['id'] as int);
                        items.removeWhere((x) => x['id'] == b['id']);
                        // Sheet có thể đã đóng trong lúc chờ DB — setSheet
                        // trên StatefulBuilder đã dispose là lỗi.
                        if (ctx.mounted) setSheet(() {});
                      },
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      _jumpToBookmark(b);
                    },
                  ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  void _jumpToBookmark(Map<String, dynamic> b) {
    final chapterUrl = b['chapter_url'] as String?;
    final para = b['para_index'] as int?;
    if (chapterUrl == null || para == null || !mounted) return;
    final c = _content;
    if (c != null && sameChapterUrl(c.url, chapterUrl)) {
      _gotoParagraph(para);
      return;
    }
    // Chương khác: mở màn đọc mới và nhảy thẳng tới đoạn.
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(
          url: chapterUrl,
          storyUrl: _storyUrlOf(chapterUrl),
          initialParagraph: para,
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
      return Text(
        p,
        key: key,
        // Nháy sáng đoạn vừa nhảy tới từ kết quả tìm kiếm (2.5s rồi tự tắt).
        style: _flashPara == i
            ? style.copyWith(backgroundColor: const Color(0x66FFB74D))
            : style,
      );
    }
    final sentences = p.split(TtsPlayer.sentenceSplit);
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
