import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/errors.dart';
import '../core/providers.dart';
import '../data/backup.dart';
import '../sources/registry.dart';
import '../sources/sources_screen.dart';
import '../update/app_updater.dart';
import 'word_fix_screen.dart';

/// Tab Cài đặt: thông tin app (phiên bản đang chạy, kiểm tra bản mới) và các
/// tuỳ chọn chung — chuyển từ menu "Tuỳ chọn thư viện" của màn Thư viện sang
/// đây để gom một chỗ, dễ tìm hơn.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Phiên bản đang chạy, nạp lúc mở tab; null là chưa nạp xong / nền không
  // trả được (máy test...) — UI hiện dấu chờ, không chặn phần còn lại.
  String? _version;
  String? _build;
  bool _autoCheck = true;
  bool _checkingUpdate = false;
  bool _busy = false; // đang sao lưu / phục hồi
  int _wordFixCount = 0; // số cụm từ sửa lỗi người dùng đã dạy

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    String? version;
    String? build;
    try {
      final info = await PackageInfo.fromPlatform();
      version = info.version;
      build = info.buildNumber;
    } catch (_) {}
    final auto =
        (await ref.read(appDbProvider).getSetting('autoCheckNew') ?? '1') ==
        '1';
    final fixes = await ref.read(appDbProvider).getWordFixes();
    if (mounted) {
      setState(() {
        _version = version;
        _build = build;
        _autoCheck = auto;
        _wordFixCount = fixes.length;
      });
    }
  }

  // Kiểm tra bản mới bất cứ lúc nào người dùng bấm: khác với lần nhắc tự động
  // lúc mở app (bản đã nhắc thì thôi), chủ động hỏi thì luôn hiện hộp thoại
  // nếu có bản mới; không thì báo đang là mới nhất.
  Future<void> _checkUpdate() async {
    if (_checkingUpdate) return;
    setState(() => _checkingUpdate = true);
    try {
      final update = await AppUpdater().check();
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Bạn đang dùng bản mới nhất'
              '${_version == null ? '' : ' (v$_version)'}',
            ),
          ),
        );
      } else {
        await AppUpdater.showUpdateDialog(
          context,
          db: ref.read(appDbProvider),
          update: update,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kiểm tra cập nhật lỗi: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  Future<void> _toggleAutoCheck(bool v) async {
    await ref.read(appDbProvider).setSetting('autoCheckNew', v ? '1' : '0');
    if (mounted) setState(() => _autoCheck = v);
  }

  Future<void> _backup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final data = await DataBackup(ref.read(appDbProvider)).export();
      final stamp = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final name =
          'story_reader_backup_${stamp.year}${two(stamp.month)}${two(stamp.day)}'
          '_${two(stamp.hour)}${two(stamp.minute)}.json';
      // Ghi vào cache/backup để FileProvider chia sẻ được. Trình chọn thư mục
      // của Android dễ lạc — chia sẻ là đường chính, lưu thư mục là đường phụ.
      final dir = Directory(
        p.join((await getTemporaryDirectory()).path, 'backup'),
      );
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, name));
      await file.writeAsString(jsonEncode(data));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Đã tạo file sao lưu'),
          content: Text(
            'File "$name" gồm thư viện, vị trí đọc và sách đã nhập.\n\n'
            'Bấm Chia sẻ để gửi sang máy khác, Drive hoặc Files.\n\n'
            'Đường dẫn trên máy này:\n${file.path}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Đóng'),
            ),
            TextButton(
              onPressed: () async {
                try {
                  final dest = await _copyBackupToFolder(file, name);
                  if (!ctx.mounted || dest == null) return;
                  Navigator.pop(ctx);
                  if (!mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('Đã lưu tại $dest')));
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Lưu thư mục lỗi: ${friendlyError(e)}'),
                    ),
                  );
                }
              },
              child: const Text('Lưu vào thư mục'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await AppUpdater.shareFile(file.path);
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Chia sẻ lỗi: ${friendlyError(e)}')),
                  );
                }
              },
              child: const Text('Chia sẻ'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sao lưu lỗi: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _copyBackupToFolder(File file, String name) async {
    final dirPath = await FilePicker.getDirectoryPath();
    if (dirPath == null) return null;
    final dest = p.join(dirPath, name);
    await file.copy(dest);
    return dest;
  }

  Future<void> _restore() async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Phục hồi từ file sao lưu?'),
        content: const Text(
          'Dữ liệu trong file sẽ được ghép vào dữ liệu hiện có, không xoá gì. '
          'Truyện, vị trí đọc và sách đã nhập sẽ trở lại như lúc sao lưu.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Phục hồi'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.pickFile(type: FileType.any);
      final path = picked?.path;
      if (!mounted) return;
      if (path == null) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Đang khôi phục dữ liệu...')),
      );
      final db = ref.read(appDbProvider);
      final data =
          jsonDecode(await File(path).readAsString()) as Map<String, dynamic>;
      await DataBackup(db).import(data);
      // Bản nguồn truyện đã cài nằm trong settings khôi phục; nạp luôn để
      // không phải mở lại app.
      await SourceRegistry.restoreInstalled(db, ref.read(adapterRepoProvider));
      // Restore ghép cả settings vào DB (kể cả tuỳ chọn tự check) — nạp lại
      // để công tắc hiển thị đúng dữ liệu vừa khôi phục.
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Đã khôi phục xong.')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Phục hồi lỗi: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          _header('Ứng dụng'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('Phiên bản'),
                  subtitle: Text(
                    _version == null
                        ? '…'
                        : 'v$_version${_build == null || _build!.isEmpty ? '' : ' (bản dựng $_build)'}',
                  ),
                ),
                ListTile(
                  leading: _checkingUpdate
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.system_update_outlined),
                  title: const Text('Kiểm tra cập nhật'),
                  subtitle: const Text('Tải bản mới hơn về cài trực tiếp'),
                  onTap: _checkingUpdate ? null : _checkUpdate,
                ),
              ],
            ),
          ),
          _header('Cài đặt chung'),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  secondary: const Icon(Icons.new_releases_outlined),
                  title: const Text('Tự kiểm tra chương mới khi mở app'),
                  value: _autoCheck,
                  onChanged: _toggleAutoCheck,
                ),
                ListTile(
                  leading: const Icon(Icons.explore_outlined),
                  title: const Text('Quản lý nguồn truyện'),
                  subtitle: const Text('Thêm, làm mới nguồn đọc truyện'),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: _busy
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => const SourcesScreen(),
                          ),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.spellcheck_outlined),
                  title: const Text('Sửa lỗi từ truyện'),
                  subtitle: Text(
                    _wordFixCount == 0
                        ? 'Dạy app thay cụm từ sai ("gi ết" → "giết")'
                        : '$_wordFixCount cụm từ đang tự thay khi đọc/nghe',
                  ),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: _busy
                      ? null
                      : () async {
                          await Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => const WordFixScreen(),
                            ),
                          );
                          // Quay lại từ màn quản lý thì đếm có thể đã đổi.
                          await _load();
                        },
                ),
              ],
            ),
          ),
          _header('Dữ liệu'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.save_outlined),
                  title: const Text('Sao lưu dữ liệu'),
                  subtitle: const Text(
                    'Tạo file, rồi chia sẻ hoặc lưu vào thư mục',
                  ),
                  onTap: _busy || _checkingUpdate ? null : _backup,
                ),
                ListTile(
                  leading: const Icon(Icons.restore_outlined),
                  title: const Text('Phục hồi từ file sao lưu'),
                  subtitle: const Text(
                    'Ghép dữ liệu từ file sao lưu vào máy này',
                  ),
                  onTap: _busy || _checkingUpdate ? null : _restore,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                'Story Reader — đọc và nghe truyện từ web',
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall?.copyWith(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.bold,
      ),
    ),
  );
}
