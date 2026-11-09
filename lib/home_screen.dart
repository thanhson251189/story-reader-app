import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'reader/reader_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _urlCtrl = TextEditingController();
  String? _lastUrl;
  List<Map<String, dynamic>> _library = [];

  @override
  void initState() {
    super.initState();
    _loadLast();
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
    final uri = Uri.tryParse(u);
    if (u.isEmpty || uri == null || !uri.hasScheme || !uri.host.contains('.')) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Link không hợp lệ, dán link chương đầy đủ (https://...)')));
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => ReaderScreen(url: u)))
        .then((_) => _loadLast());
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
      appBar: AppBar(title: const Text('Story Reader')),
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
          const SizedBox(height: 24),
          if (_lastUrl != null) ...[
            Text('Đọc tiếp', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.history),
                title: Text(_lastUrl!, maxLines: 2, overflow: TextOverflow.ellipsis),
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
                    child: item['cover_url'] != null
                        ? Image.network(item['cover_url'] as String,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => const Icon(Icons.book, size: 40))
                        : const Icon(Icons.book, size: 40),
                  ),
                  title: Text(item['title'] as String? ?? '',
                      maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                      Uri.tryParse(item['last_chapter_url'] as String? ?? '')
                              ?.pathSegments
                              .lastOrNull ??
                          '',
                      maxLines: 1),
                  trailing: const Icon(Icons.arrow_forward),
                  onTap: () => _open(
                      (item['last_chapter_url'] as String?) ?? item['story_url'] as String),
                  onLongPress: () => _removeLib(item),
                ),
              ),
          ],
        ],
      ),
    );
  }
}