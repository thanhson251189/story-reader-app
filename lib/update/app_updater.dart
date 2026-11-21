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
    await showDialog<void>(
      context: context,
      builder: (_) => _UpdateDialog(update: update, db: db),
    );
    return true;
  }
}

class _UpdateDialog extends StatefulWidget {
  final UpdateInfo update;
  final AppDb db;
  const _UpdateDialog({required this.update, required this.db});

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
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

  Future<void> _start() async {
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
