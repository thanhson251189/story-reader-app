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
  Map<String, String> _names = {};
  String _appVersion = '';
  bool _loading = true;
  bool _updatingAll = false;
  String? _error;
  String? _busyId;
  String? _allProgress;

  List<SourceEntry> get _updates =>
      SourceRegistry.pendingUpdates(_entries, _registry.adapters, _appVersion);

  @override
  void initState() {
    super.initState();
    _registry = SourceRegistry(
      ref.read(appDbProvider),
      ref.read(adapterRepoProvider),
    );
    _init();
  }

  Future<void> _init() async {
    _urlCtrl.text = await _registry.indexUrl();
    _appVersion = await _registry.appVersion();
    await _refresh();
  }

  Future<void> _refresh() async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final entries = await _registry.loadIndex();
      final names = await _registry.nameOverrides();
      if (mounted) {
        setState(() {
          _entries = entries;
          _names = names;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Không tải được index: $e';
        });
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Đã thêm nguồn ${e.name}')));
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

  Future<void> _updateAll() async {
    final updates = _updates;
    setState(() => _updatingAll = true);
    var ok = 0;
    final errs = <String>[];
    for (var i = 0; i < updates.length; i++) {
      final e = updates[i];
      setState(() {
        _busyId = e.id;
        _allProgress =
            'Đang cập nhật ${i + 1}/${updates.length}: ${_names[e.domain] ?? e.name}';
      });
      try {
        await _registry.install(e);
        ok++;
      } catch (err) {
        errs.add('${e.name}: $err');
      }
    }
    if (!mounted) return;
    setState(() {
      _updatingAll = false;
      _allProgress = null;
      _busyId = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          errs.isEmpty
              ? 'Đã cập nhật $ok nguồn'
              : 'Cập nhật $ok nguồn, lỗi: ${errs.join('; ')}',
        ),
      ),
    );
  }

  Future<void> _rename(SourceEntry e) async {
    final ctrl = TextEditingController(text: _names[e.domain] ?? e.name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Đổi tên nguồn ${e.domain}'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Tên hiển thị'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    final name = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true || name.isEmpty || !mounted) return;
    await _registry.setName(e.domain, name);
    setState(() => _names[e.domain] = name);
  }

  Future<void> _confirmDelete(SourceEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Xóa nguồn ${_names[e.domain] ?? e.name}?'),
        content: const Text(
          'Truyện trong thư viện từ nguồn này sẽ không mở được cho tới khi cài lại nguồn.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _registry.uninstall(e.domain);
    if (!mounted) return;
    setState(() => _names.remove(e.domain));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Đã xóa nguồn ${e.name}')));
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
            tooltip: 'Cập nhật tất cả',
            icon: const Icon(Icons.system_update_alt),
            onPressed: _loading || _updatingAll || _updates.isEmpty
                ? null
                : _updateAll,
          ),
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
          Text(
            'App v$_appVersion',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_allProgress != null) ...[
            const SizedBox(height: 8),
            Text(_allProgress!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
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
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
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
    final menu = inst == null
        ? null
        : PopupMenuButton<String>(
            enabled: _busyId == null && !_updatingAll,
            tooltip: 'Tùy chọn nguồn',
            onSelected: (v) => v == 'rename' ? _rename(e) : _confirmDelete(e),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
              PopupMenuItem(value: 'delete', child: Text('Xóa')),
            ],
          );
    return Card(
      child: ListTile(
        leading: const Icon(Icons.dns_outlined),
        title: Text(_names[e.domain] ?? e.name),
        subtitle: Text('${e.domain}\n$label'),
        isThreeLine: true,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [?action, ?menu],
        ),
      ),
    );
  }
}
