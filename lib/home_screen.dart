import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:io';
import 'core/providers.dart';
import 'local/book_importer.dart';
import 'reader/reader_screen.dart';
import 'sources/registry.dart';
import 'sources/sources_screen.dart';
import 'update/app_updater.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _urlCtrl = TextEditingController();
  String? _lastUrl;
  List<Map<String, dynamic>> _library = [];
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _loadLast();
    unawaited(_warmRegistry());
    unawaited(AppUpdater.showIfAny(context).catchError((_) => false));
  }

  Future<void> _manualUpdate() async {
    try {
      final shown = await AppUpdater.showIfAny(context);
      if (!shown && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Đang là bản mới nhất (hoặc không với tới GitHub).')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Không kiểm tra được: $e')));
      }
    }
  }

  Future<void> _warmRegistry() async {
    try {
      await SourceRegistry(
              ref.read(appDbProvider), ref.read(adapterRepoProvider))
          .loadIndex();
    } catch (_) {}
  }

  Future<void> _loadLast() async {
    final db = ref.read(appDbProvider);
    final last = await db.getSetting('lastUrl');
    final lib = await db.getLibrary();
    if (mounted) {
      setState(() {
        _lastUrl = last;
        _library = lib;
      });
    }
  }

  void _open(String url) {
    final u = url.trim();
    if (u.startsWith('book:')) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderScreen(url: u)))
          .then((_) => _loadLast());
      return;
    }
    final uri = Uri.tryParse(u);
    if (u.isEmpty || uri == null || !uri.hasScheme || !uri.host.contains('.')) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link không hợp lệ, dán link chương đầy đủ (https://...)')));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderScreen(url: u)))
        .then((_) => _loadLast());
  }

  Future<void> _importBook() async {
    if (_importing) return;
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(type: FileType.any);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Không mở được trình chọn file: $e')));
      }
      return;
    }
    final path = picked?.path;
    if (path == null || !mounted) return;
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    const supported = {'epub', 'mobi', 'azw', 'azw3', 'fb2', 'txt'};
    if (!supported.contains(ext)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Chưa hỗ trợ .$ext — chỉ đọc được EPUB, MOBI, FB2, TXT')));
      return;
    }
    setState(() => _importing = true);
    try {
      final result = await BookImporter(ref.read(appDbProvider)).importFile(path);
      await _loadLast();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Đã nhập "${result.title}" (${result.chapters} chương)')));
      _open('${result.storyUrl}:0');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Nhập sách lỗi: ${e.toString().replaceFirst('FormatException: ', '')}')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  String _libSubtitle(Map<String, dynamic> item) {
    final last = item['last_chapter_url'] as String? ?? '';
    if (last.startsWith('book:')) {
      final n = int.tryParse(last.split(':').last);
      return n == null ? 'Sách trong máy' : 'Chương ${n + 1}';
    }
    return Uri.tryParse(last)?.pathSegments.lastOrNull ?? '';
  }

  String _lastLabel() {
    final last = _lastUrl!;
    if (!last.startsWith('book:')) return last;
    final parts = last.split(':');
    final story = parts.length >= 2 ? '${parts[0]}:${parts[1]}' : last;
    final title = _library
        .where((e) => e['story_url'] == story)
        .map((e) => e['title'] as String?)
        .firstOrNull;
    final n = int.tryParse(parts.last);
    final chapter = n == null ? '' : ' — Chương ${n + 1}';
    return title == null ? 'Sách trong máy$chapter' : '$title$chapter';
  }

  Widget _cover(Map<String, dynamic> item) {
    final cover = item['cover_url'] as String?;
    Widget fallback(_, _, _) => const Icon(Icons.book, size: 40);
    if (cover == null || cover.isEmpty) return const Icon(Icons.book, size: 40);
    if (cover.startsWith('http')) {
      return Image.network(cover, fit: BoxFit.cover, errorBuilder: fallback);
    }
    return Image.file(File(cover), fit: BoxFit.cover, errorBuilder: fallback);
  }

  Future<void> _removeLib(Map<String, dynamic> item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Xoá khỏi thư viện?'),
        content: Text(item['title'] as String? ?? ''),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Huỷ')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Xoá')),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(appDbProvider).removeFromLibrary(item['story_url'] as String);
      final cover = item['cover_url'] as String?;
      if (cover != null && !cover.startsWith('http')) {
        try {
          final f = File(cover);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      await _loadLast();
    }
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Story Reader'), actions: [
        IconButton(
          tooltip: 'Nguồn truyện',
          icon: const Icon(Icons.dns_outlined),
          onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SourcesScreen())),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              labelText: 'Link chương truyện',
              hintText: 'https://...',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: const Icon(Icons.content_paste),
                tooltip: 'Dán',
                onPressed: () async {
                  final data = await Clipboard.getData(Clipboard.kTextPlain);
                  if (data?.text != null) _urlCtrl.text = data!.text!;
                },
              ),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: _open,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => _open(_urlCtrl.text),
            icon: const Icon(Icons.menu_book),
            label: const Text('Mở truyện'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _importing ? null : _importBook,
            icon: const Icon(Icons.file_open_outlined),
            label: Text(_importing ? 'Đang nhập sách...' : 'Đọc file trong máy (EPUB, MOBI, FB2, TXT)'),
          ),
          if (_importing) ...[
            const SizedBox(height: 12),
            const LinearProgressIndicator(minHeight: 3),
          ],
          const SizedBox(height: 24),
          if (_lastUrl != null) ...[
            Text('Đọc tiếp', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.history),
                title: Text(_lastLabel(), maxLines: 2, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.arrow_forward),
                onTap: () => _open(_lastUrl!),
              ),
            ),
            const SizedBox(height: 24),
          ],
          if (_library.isNotEmpty) ...[
            Text('Thư viện', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final item in _library)
              Card(
                child: ListTile(
                  leading: SizedBox(
                    width: 48,
                    height: 64,
                    child: _cover(item),
                  ),
                  title: Text(item['title'] as String? ?? '',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_libSubtitle(item), maxLines: 1),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: () => _open(
                      (item['last_chapter_url'] as String?) ?? item['story_url'] as String),
                  onLongPress: () => _removeLib(item),
                ),
              ),
          ],
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: _manualUpdate,
            icon: const Icon(Icons.system_update_alt),
            label: const Text('Kiểm tra cập nhật'),
          ),
        ],
      ),
    );
  }
}