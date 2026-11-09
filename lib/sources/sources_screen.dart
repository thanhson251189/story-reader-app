import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'registry.dart';

class SourcesScreen extends ConsumerStatefulWidget {
  const SourcesScreen({super.key});

  @override
  ConsumerState<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends ConsumerState<SourcesScreen> {
  final _urlCtrl = TextEditingController();
  late final SourceRegistry _registry;
  List<SourceEntry> _entries = [];
  String _appVersion = '';
  bool _loading = true;
  String? _error;
  String? _busyId;

  @override
  void initState() {
    super.initState();
    _registry =
        SourceRegistry(ref.read(appDbProvider), ref.read(adapterRepoProvider));
    _init();
  }

  Future<void> _init() async {
    _urlCtrl.text = await _registry.indexUrl();
    _appVersion = await _registry.appVersion();
    await _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) setState(() { _loading = true; _error = null; });
    try {
      final entries = await _registry.loadIndex();
      if (mounted) setState(() { _entries = entries; _loading = false; });
    } catch (e) {
      if (mounted) {
        setState(() { _loading = false; _error = 'Không tải được index: $e'; });
      }
    }
  }

  Future<void> _saveUrl() async {
    await _registry.setIndexUrl(_urlCtrl.text.trim());
    await _refresh();
  }

  Future<void> _install(SourceEntry e) async {
    setState(() => _busyId = e.id);
    try {
      await _registry.install(e);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Đã thêm nguồn ${e.name}')));
        setState(() {});
      }
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Lỗi: $err')));
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
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
      appBar: AppBar(
        title: const Text('Nguồn truyện'),
        actions: [
          IconButton(
            tooltip: 'Làm mới',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              labelText: 'Link index.json',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                tooltip: 'Lưu & làm mới',
                icon: const Icon(Icons.save),
                onPressed: _saveUrl,
              ),
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
            onSubmitted: (_) => _saveUrl(),
          ),
          const SizedBox(height: 8),
          Text('App v$_appVersion',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          if (!_loading && _error == null && _entries.isEmpty)
            const Text('Chưa có index (mất mạng hoặc link sai).'),
          for (final e in _entries) _row(e),
        ],
      ),
    );
  }

  Widget _row(SourceEntry e) {
    final inst = _registry.installed(e.domain);
    final needsAppUpdate =
        SourceRegistry.compareVersions(e.minAppVersion, _appVersion) > 0;
    String label;
    Widget? action;
    if (needsAppUpdate) {
      label = 'Cần cập nhật app trước';
    } else if (inst == null) {
      label = 'Mới';
      action = FilledButton.tonal(
        onPressed: _busyId == null ? () => _install(e) : null,
        child: _busyId == e.id
            ? const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Thêm'),
      );
    } else if (e.version > inst.version) {
      label = 'Có bản cập nhật (v${inst.version} → v${e.version})';
      action = FilledButton.tonal(
        onPressed: _busyId == null ? () => _install(e) : null,
        child: const Text('Cập nhật'),
      );
    } else {
      label = 'Đã cài v${inst.version}';
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: Text(e.name),
        subtitle: Text('${e.domain}\n$label'),
        isThreeLine: true,
        trailing: action,
      ),
    );
  }
}