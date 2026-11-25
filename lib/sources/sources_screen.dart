import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors.dart';
import '../core/models.dart';
import '../core/providers.dart';
import '../update/app_updater.dart';
import 'registry.dart';
import 'source_login_screen.dart';

class SourcesScreen extends ConsumerStatefulWidget {
  /// [openInDiscover] = true khi mở từ tab Khám phá: chạm "Mở"/cả dòng sẽ
  /// chọn nguồn đó và quay về. Mở từ Cài đặt (false) thì các nút chọn nguồn
  /// ẩn đi — bấm chúng ở đó chỉ đóng màn, tưởng là nút hỏng.
  final bool openInDiscover;
  const SourcesScreen({super.key, this.openInDiscover = false});

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
    if (updates.isEmpty) return;
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

  /// Bản cài mới có danh sách nguồn nhưng chưa cài gì: cài nhanh các nguồn
  /// thường (bỏ 18+ và nguồn đòi app mới hơn) trong một lần bấm.
  Future<void> _installDefaultSources() async {
    final targets = _entries
        .where(
          (e) =>
              !e.adult &&
              _registry.installed(e.domain) == null &&
              SourceRegistry.compareVersions(e.minAppVersion, _appVersion) <= 0,
        )
        .toList();
    if (targets.isEmpty) return;
    setState(() => _updatingAll = true);
    var ok = 0;
    final errs = <String>[];
    for (var i = 0; i < targets.length; i++) {
      final e = targets[i];
      setState(() {
        _busyId = e.id;
        _allProgress =
            'Đang cài ${i + 1}/${targets.length}: ${_names[e.domain] ?? e.name}';
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
              ? 'Đã cài $ok nguồn'
              : 'Đã cài $ok nguồn, lỗi: ${errs.join('; ')}',
        ),
      ),
    );
  }

  /// Cần bản app mới hơn mới dùng được nguồn: cho bấm cập nhật ngay tại chỗ
  /// thay vì bắt người dùng tự mò sang Cài đặt.
  Future<void> _checkAppUpdate() async {
    if (_updatingAll || _busyId != null) return;
    setState(() => _busyId = '__app__');
    try {
      final update = await AppUpdater().check();
      if (!mounted) return;
      if (update == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Bạn đang dùng bản mới nhất')),
        );
        return;
      }
      await AppUpdater.showUpdateDialog(
        context,
        db: ref.read(appDbProvider),
        update: update,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Kiểm tra cập nhật lỗi: ${friendlyError(e)}')),
        );
      }
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  /// Mở từ Cài đặt: dòng nguồn không "Mở" sang Khám phá được, nên chạm dòng
  /// hiện bảng thao tác thay vì im lặng.
  Future<void> _showSourceActions(
    SourceEntry e,
    SourceAdapter adapter,
    String name,
  ) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('https://${e.domain}'),
            ),
            const Divider(height: 1),
            if (adapter.loginUrl != null)
              ListTile(
                leading: const Icon(Icons.login),
                title: const Text('Đăng nhập'),
                onTap: () => Navigator.pop(ctx, 'login'),
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Đổi tên'),
              onTap: () => Navigator.pop(ctx, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Xóa nguồn'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'login') {
      openSourceLogin(context, adapter, name);
    } else if (action == 'rename') {
      _rename(e);
    } else if (action == 'delete') {
      _confirmDelete(e);
    }
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
    final installable = _entries
        .where(
          (e) =>
              !e.adult &&
              _registry.installed(e.domain) == null &&
              SourceRegistry.compareVersions(e.minAppVersion, _appVersion) <= 0,
        )
        .length;
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
          if (_allProgress != null) ...[
            Text(_allProgress!, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
          ],
          Wrap(
            spacing: 8,
            children: [
              _filterChip(_Filter.all, 'Tất cả'),
              _filterChip(_Filter.installed, 'Đã cài'),
              _filterChip(_Filter.notInstalled, 'Chưa cài'),
            ],
          ),
          if (!_loading && _error == null && installable > 0)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FilledButton.tonalIcon(
                onPressed: _updatingAll || _busyId != null
                    ? null
                    : _installDefaultSources,
                icon: const Icon(Icons.download_for_offline_outlined),
                label: Text(
                  _registry.adapters.all.isEmpty
                      ? 'Cài các nguồn có sẵn (trừ 18+)'
                      : 'Cài nốt nguồn còn lại (trừ 18+)',
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_loading) const Center(child: CircularProgressIndicator()),
          if (!_loading && _error != null && _entries.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 12,
                ),
              ),
            ),
          if (!_loading && _entries.isEmpty)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _error ??
                      'Chưa tải được danh sách nguồn. Kiểm tra mạng rồi thử lại.',
                  style: TextStyle(
                    color: _error == null
                        ? null
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Thử lại'),
                ),
              ],
            ),
          if (!_loading &&
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
    final adapter = inst;
    final name = SourceRegistry.displayName(e, _names);
    final canSelect = widget.openInDiscover && adapter != null;
    String label;
    Widget? action;
    if (needsAppUpdate) {
      label = 'Cần bản app mới hơn để dùng nguồn này';
      action = IconButton(
        tooltip: 'Cập nhật app',
        icon: _busyId == '__app__'
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.system_update_outlined),
        onPressed: _updatingAll || _busyId != null ? null : _checkAppUpdate,
      );
    } else if (adapter == null) {
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
    } else if (e.version > adapter.version) {
      label = 'Có bản cập nhật (v${adapter.version} → v${e.version})';
      action = FilledButton.tonal(
        onPressed: _busyId == null ? () => _install(e) : null,
        child: const Text('Cập nhật'),
      );
    } else {
      label = 'Đã cài v${adapter.version}';
      // Chỉ tab Khám phá mới cần chọn nguồn; mở từ Cài đặt thì nút "Mở"
      // chẳng có tác dụng gì nên ẩn đi.
      if (canSelect) {
        action = FilledButton.tonal(
          onPressed: () => Navigator.pop(context, e.domain),
          child: const Text('Mở'),
        );
      }
    }
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
              if (adapter.loginUrl != null)
                const PopupMenuItem(value: 'login', child: Text('Đăng nhập')),
              const PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
              const PopupMenuItem(value: 'delete', child: Text('Xóa')),
            ],
          );
    return Card(
      child: ListTile(
        onTap: canSelect
            ? () => Navigator.pop(context, e.domain)
            : (adapter == null
                  ? null
                  : () => _showSourceActions(e, adapter, name)),
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
