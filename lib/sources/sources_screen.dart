import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/providers.dart';
import 'registry.dart';
import 'source_login_screen.dart';

class SourcesScreen extends ConsumerStatefulWidget {
  const SourcesScreen({super.key});

  @override
  ConsumerState<SourcesScreen> createState() => _SourcesScreenState();
}

enum _Filter { all, installed, notInstalled }

class _SourcesScreenState extends ConsumerState<SourcesScreen> {
  late final SourceRegistry _registry;
  List<SourceEntry> _entries = [];
  Map<String, String> _names = {};
  String _appVersion = '';
  bool _loading = true;
  bool _updatingAll = false;
  String? _error;
  String? _busyId;
  String? _allProgress;
  _Filter _filter = _Filter.all;

  List<SourceEntry> get _updates =>
      SourceRegistry.pendingUpdates(_entries, _registry.adapters, _appVersion);

  List<SourceEntry> get _visible {
    final filtered = _entries.where((e) {
      final installed = _registry.installed(e.domain) != null;
      return switch (_filter) {
        _Filter.all => true,
        _Filter.installed => installed,
        _Filter.notInstalled => !installed,
      };
    });
    return SourceRegistry.sortedForDisplay(
      filtered,
      _names,
      _registry.adapters,
    );
  }

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
          _error = 'Không tải được danh sách nguồn: ${friendlyError(e)}';
        });
      }
    }
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
            .showSnackBar(SnackBar(content: Text(friendlyError(err))));
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
        errs.add('${e.name}: ${friendlyError(err)}');
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
    final ctrl = TextEditingController(
      text: SourceRegistry.displayName(e, _names),
    );
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Đổi tên nguồn'),
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
        title: Text('Xóa nguồn ${SourceRegistry.displayName(e, _names)}?'),
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
          // Danh sách nguồn do app tự cung cấp: không hiện link registry cho
          // người dùng sửa. Setting cũ trong máy vẫn được dùng để tải.
          Text(
            'App v$_appVersion',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_allProgress != null) ...[
            const SizedBox(height: 8),
            Text(_allProgress!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              _filterChip(_Filter.all, 'Tất cả'),
              _filterChip(_Filter.installed, 'Đã cài'),
              _filterChip(_Filter.notInstalled, 'Chưa cài'),
            ],
          ),
          const SizedBox(height: 8),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (!_loading && _error == null && _entries.isEmpty)
            const Text('Chưa có danh sách nguồn (mất mạng hoặc link sai).'),
          if (!_loading &&
              _error == null &&
              _entries.isNotEmpty &&
              _visible.isEmpty)
            Text(
              _filter == _Filter.installed
                  ? 'Chưa cài nguồn nào.'
                  : 'Mọi nguồn trong danh sách đã cài.',
            ),
          for (final e in _visible) _row(e),
        ],
      ),
    );
  }

  Widget _filterChip(_Filter f, String label) => ChoiceChip(
    label: Text(label),
    selected: _filter == f,
    showCheckmark: false,
    visualDensity: VisualDensity.compact,
    onSelected: (_) => setState(() => _filter = f),
  );

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
      // Bấm Mở (hoặc chạm cả dòng) trả domain về tab Khám phá để mở trang nguồn.
      action = FilledButton.tonal(
        onPressed: () => Navigator.pop(context, e.domain),
        child: const Text('Mở'),
      );
    }
    final adapter = inst;
    final name = SourceRegistry.displayName(e, _names);
    final loginUrl = adapter?.loginUrl;
    final menu = adapter == null
        ? null
        : PopupMenuButton<String>(
            enabled: _busyId == null && !_updatingAll,
            tooltip: 'Tùy chọn nguồn',
            onSelected: (v) {
              if (v == 'rename') {
                _rename(e);
              } else if (v == 'login') {
                openSourceLogin(context, adapter, name);
              } else if (v == 'delete') {
                _confirmDelete(e);
              }
            },
            itemBuilder: (_) => [
              if (loginUrl != null)
                const PopupMenuItem(value: 'login', child: Text('Đăng nhập')),
              const PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
              const PopupMenuItem(value: 'delete', child: Text('Xóa')),
            ],
          );
    return Card(
      child: ListTile(
        onTap: inst == null ? null : () => Navigator.pop(context, e.domain),
        leading: const Icon(Icons.dns_outlined),
        title: Row(
          children: [
            Flexible(child: Text(name)),
            if (e.adult) ...[const SizedBox(width: 6), _adultBadge()],
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Tên nguồn đổi được nên không cho biết nguồn trỏ trang nào;
            // domain là địa chỉ thật, luôn hiện.
            Text(
              'https://${e.domain}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Text(label),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [?action, ?menu],
        ),
      ),
    );
  }

  Widget _adultBadge() {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '18+',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: scheme.onErrorContainer,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
