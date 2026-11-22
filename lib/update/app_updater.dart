import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/errors.dart';
import '../data/app_db.dart';
import '../sources/registry.dart';

class UpdateInfo {
  final String version;
  final String changelog;
  // Release kèm APK thì là link tải trực tiếp; không thì là link trang release.
  final String url;
  final bool directApk;
  UpdateInfo({
    required this.version,
    required this.changelog,
    required this.url,
    required this.directApk,
  });
}

class AppUpdater {
  static const repoApi =
      'https://api.github.com/repos/thanhson251189/story-reader-app/releases/latest';
  static const _installerChannel = MethodChannel('story_reader/updater');
  // GitHub không phục vụ asset cho request không có User-Agent.
  static const _ua = 'story-reader-app';

  Future<UpdateInfo?> check() async {
    final current = (await PackageInfo.fromPlatform()).version;
    final res = await http
        .get(Uri.parse(repoApi))
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200) return null;
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    final tag = (j['tag_name'] as String? ?? '').replaceFirst(
      RegExp(r'^v'),
      '',
    );
    if (tag.isEmpty || SourceRegistry.compareVersions(tag, current) <= 0) {
      return null;
    }
    final assets = (j['assets'] as List? ?? [])
        .where((a) => (a['name'] as String? ?? '').endsWith('.apk'))
        .toList();
    return UpdateInfo(
      version: tag,
      changelog: j['body'] as String? ?? '',
      url: assets.isNotEmpty
          ? assets.first['browser_download_url'] as String
          : j['html_url'] as String,
      directApk: assets.isNotEmpty,
    );
  }

  /// Tải file APK về savePath, báo tiến độ từng khối (byte đã nhận, tổng nếu
  /// server trả về). Lỗi thì xoá file lẻ. Truyền client từ ngoài để huỷ được;
  /// [stallTimeout] là khoảng nghỉ tối đa giữa hai lần nhận dữ liệu — nghẽn
  /// mạng quá lâu sẽ hủy để dialog không treo ở trạng thái đang tải.
  static Future<String> downloadApk(
    String url,
    String savePath,
    void Function(int received, int? total) onProgress, {
    http.Client? client,
    Duration stallTimeout = const Duration(seconds: 30),
  }) async {
    final owned = client == null;
    final c = client ?? http.Client();
    final file = File(savePath);
    try {
      final req = http.Request('GET', Uri.parse(url))
        ..headers['User-Agent'] = _ua;
      final res = await c.send(req).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
      final total = res.contentLength;
      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in res.stream.timeout(stallTimeout)) {
          received += chunk.length;
          sink.add(chunk);
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return savePath;
    } catch (_) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
      rethrow;
    } finally {
      if (owned) c.close();
    }
  }

  /// Xoá file APK cài đặt còn sót từ lần cập nhật trước. Trình cài hệ thống
  /// không gọi lại app khi cài xong nên không biết được khoảnh khắc "cài
  /// xong" chính xác — nhưng lần đầu mở app sau khi cài là chắc chắn sau đó,
  /// và file này không còn dùng được nữa (lần tải kế luôn ghi đè file mới).
  /// Xoá cả thư mục update cho sạch; lỗi bỏ qua, không ảnh hưởng app.
  static Future<void> cleanupLeftoverApk() async {
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'update'),
      );
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  static Future<bool> showIfAny(BuildContext context, AppDb db) async {
    final update = await AppUpdater().check();
    if (update == null) return false;
    // Người dùng đã từng thấy hộp thoại của bản này rồi thì thôi hỏi lại
    // (mọi đường đóng hộp thoại đều ghi nhớ — xem _UpdateDialogState.dispose);
    // ra bản mới hơn sẽ hỏi tiếp.
    if (await db.getSetting('updatePromptedVersion') == update.version) {
      return false;
    }
    if (!context.mounted) return false;
    await showUpdateDialog(context, db: db, update: update);
    return true;
  }

  /// Hộp thoại cập nhật cho bản đã tra sẵn. Nút "Kiểm tra cập nhật" ở tab
  /// Cài đặt dùng hàm này thay vì showIfAny: người dùng chủ động hỏi thì
  /// phải hiện hộp thoại kể cả khi đã từng nhắc bản đó rồi.
  static Future<void> showUpdateDialog(
    BuildContext context, {
    required AppDb db,
    required UpdateInfo update,
  }) {
    return showDialog<void>(
      context: context,
      builder: (_) => _UpdateDialog(update: update, db: db),
    );
  }
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo update;
  final AppDb db;
  const _UpdateDialog({required this.update, required this.db});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog>
    with WidgetsBindingObserver {
  static const _mb = 1024 * 1024;
  static const _uiStep = 256 * 1024; // nhịp cập nhật progress bar

  http.Client? _client;
  bool _downloading = false;
  bool _downloaded = false;
  bool _cancelled = false;
  // Đã bấm "Cài đặt" (mở trình cài hệ thống hoặc mở trang tải): nếu cài không
  // xong thì lần mở app sau PHẢI hỏi lại — không ghi nhớ bản đã hỏi.
  bool _installAttempted = false;
  int _received = 0;
  int? _total;
  String? _apkPath;
  String? _error;
  // Quyền "cài ứng dụng không rõ nguồn": tra TRƯỚC khi tải — thiếu quyền mà
  // để tải xong 60MB mới báo lỗi là phí cả mạng lẫn thời gian người dùng.
  bool _canInstall = true;
  bool _permChecked = false;
  // Đã từng bấm "Cấp quyền": quay lại app sau khi bật quyền xong là TỰ TẢI
  // luôn như bước Cấp quyền đã hứa — không bắt bấm nút tải thêm lần nữa.
  bool _permRequested = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkInstallPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    // Quay lại từ màn cấp quyền: tra lại quyền. Đã tải xong mà đủ quyền thì
    // tự cài luôn — người dùng không phải bấm Cài đặt thêm lần nữa.
    _checkInstallPermission().then((_) {
      if (!mounted) return;
      if (_canInstall && _downloaded && _apkPath != null) {
        _install();
      } else if (_permRequested &&
          _canInstall &&
          !_downloading &&
          !_downloaded) {
        // Vừa bật quyền xong mà chưa tải: tự tải về và cài ngay đúng như
        // bước Cấp quyền đã hứa. Chỉ tự động khi user ĐÃ chủ động bấm
        // "Cấp quyền" (biểu lộ ý định cài) — quay lại app vì lý do khác
        // thì vẫn đứng yên chờ.
        _permRequested = false;
        _start();
      }
    });
  }

  Future<void> _checkInstallPermission() async {
    bool ok;
    try {
      ok =
          await AppUpdater._installerChannel.invokeMethod<bool>(
            'canInstallApks',
          ) ??
          true;
    } catch (_) {
      // Không tra được (máy lạ, test...) thì cứ vào flow tải — native sẽ
      // chặn và mở màn cấp quyền ở bước cài nếu thật sự thiếu.
      ok = true;
    }
    if (!mounted) return;
    setState(() {
      _canInstall = ok;
      _permChecked = true;
    });
  }

  Future<void> _openPermissionSettings() async {
    _permRequested = true;
    try {
      await AppUpdater._installerChannel.invokeMethod(
        'openInstallPermissionSettings',
      );
    } catch (_) {}
  }

  Future<void> _start() async {
    // Thiếu quyền cài chỉ chặn đường tải APK trực tiếp: release không kèm APK
    // (mở trang tải qua trình duyệt) không cần quyền này — bắt cấp quyền là
    // chặn oan cả nút "Mở trang tải".
    if (widget.update.directApk && !_canInstall) {
      _openPermissionSettings();
      return;
    }
    if (widget.update.directApk) {
      await _download();
      if (_apkPath != null && mounted) await _install();
    } else {
      // Release không kèm APK: mở trang tải như cách cũ.
      Navigator.pop(context);
      await launchUrl(
        Uri.parse(widget.update.url),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _error = null;
      _received = 0;
      _total = null;
    });
    try {
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'update'),
      );
      await dir.create(recursive: true);
      final path = p.join(dir.path, 'story_reader_update.apk');
      _client = http.Client();
      var lastUi = 0;
      await AppUpdater.downloadApk(widget.update.url, path, (r, t) {
        if (r == t || r - lastUi >= _uiStep) {
          lastUi = r;
          if (mounted) {
            setState(() {
              _received = r;
              _total = t;
            });
          }
        }
      }, client: _client);
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _downloaded = true;
        _apkPath = path;
      });
    } catch (e) {
      if (!mounted || _cancelled) return;
      setState(() {
        _downloading = false;
        _error = e is TimeoutException
            ? 'Mạng quá chậm hoặc mất kết nối khi tải, hãy thử lại.'
            : 'Tải về lỗi: ${friendlyError(e)}';
      });
    } finally {
      _client = null;
    }
  }

  Future<void> _install() async {
    final path = _apkPath;
    if (path == null) return;
    _installAttempted = true;
    try {
      final ok = await AppUpdater._installerChannel.invokeMethod<bool>(
        'installApk',
        path,
      );
      if (!mounted) return;
      if (ok == true) {
        Navigator.pop(context);
      } else {
        // Native đã mở sẵn màn hình cấp quyền; giữ dialog để bấm lại.
        setState(() {
          _error =
              'Hãy cho phép Story Reader "Cài ứng dụng không rõ nguồn" '
              'trong màn hình vừa mở, rồi bấm Cài đặt.';
        });
      }
    } on PlatformException catch (e) {
      if (mounted) {
        // File lẻ/hỏng (hệ thống dọn cache...): cho phép tải lại thay vì
        // bấm Cài đặt thêm lần nữa cũng không được.
        setState(() {
          _downloaded = false;
          _error = e.message ?? 'Không mở được trình cài đặt';
        });
      }
    }
  }

  void _cancel() {
    _cancelled = true;
    _client?.close();
    Navigator.pop(context);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // Đóng hộp thoại giữa lúc tải (chạm ngoài, nút hệ thống) cũng phải ngắt
    // tải: client không close là stream vẫn tải ngầm tới xong vô ích.
    _client?.close();
    // Người dùng chần chừ (Để sau, Huỷ giữa lúc tải, đóng hộp thoại) thì ghi
    // nhớ bản đã hỏi để không hỏi lại mỗi lần mở app. ĐÃ bấm Cài đặt mà cài
    // không xong (hủy ở trình cài hệ thống...) thì KHÔNG ghi nhớ — lần mở app
    // sau vẫn phải nhắc. Ra bản mới hơn thì luôn hỏi tiếp (showIfAny).
    if (!_installAttempted) {
      try {
        widget.db.setSetting('updatePromptedVersion', widget.update.version);
      } catch (_) {}
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Cập nhật lên v${widget.update.version}'),
      content: _content(),
      actions: _actions(),
    );
  }

  Widget _content() {
    if (!_permChecked) {
      return const SizedBox(
        height: 24,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (widget.update.directApk && !_canInstall && !_downloaded && _error == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Cần quyền "Cài ứng dụng không rõ nguồn" để cài bản cập nhật.',
          ),
          const SizedBox(height: 8),
          Text(
            'Bấm "Cấp quyền" → bật cho Story Reader → quay lại app, ứng '
            'dụng sẽ tự tải về và cài tiếp.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }
    if (_downloading) {
      final total = _total;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(
            value: total == null || total == 0
                ? null
                : (_received / total).clamp(0.0, 1.0),
          ),
          const SizedBox(height: 8),
          Text(
            total == null
                ? '${(_received / _mb).toStringAsFixed(1)} MB'
                : '${(_received / _mb).toStringAsFixed(1)} / '
                      '${(total / _mb).toStringAsFixed(1)} MB '
                      '(${(100 * _received / total).round()}%)',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    }
    if (_error != null && !_downloaded) return Text(_error!);
    if (_downloaded) {
      return Text(
        _error ?? 'Đã tải xong bản cài đặt. Bấm Cài đặt để cài lên máy.',
      );
    }
    return SingleChildScrollView(
      child: Text(
        widget.update.changelog.isEmpty
            ? 'Có bản mới hơn bản đang chạy.'
            : widget.update.changelog,
      ),
    );
  }

  List<Widget> _actions() {
    final later = TextButton(
      onPressed: () => Navigator.pop(context),
      child: const Text('Để sau'),
    );
    if (!_permChecked) return [later];
    if (widget.update.directApk &&
        !_canInstall &&
        !_downloaded &&
        _error == null) {
      return [
        later,
        FilledButton(
          onPressed: _openPermissionSettings,
          child: const Text('Cấp quyền'),
        ),
      ];
    }
    if (_downloading) {
      return [TextButton(onPressed: _cancel, child: const Text('Huỷ'))];
    }
    if (_downloaded) {
      // APK còn nguyên trên máy: chỉ cài lại, không tải lại cả file.
      return [
        later,
        FilledButton(onPressed: _install, child: const Text('Cài đặt')),
      ];
    }
    if (_error != null) {
      return [
        later,
        FilledButton(onPressed: _start, child: const Text('Thử lại')),
      ];
    }
    return [
      later,
      FilledButton(
        onPressed: _start,
        child: Text(
          widget.update.directApk ? 'Tải về & cài đặt' : 'Mở trang tải',
        ),
      ),
    ];
  }
}
