import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/app_db.dart';

/// Màn quản lý danh sách từ/cụm từ sửa lỗi: nguồn truyện đôi khi chèn nhầm
/// khoảng trắng giữa các ký tự ("gi ết", "thi th ể") — người dùng dạy app
/// thay cụm từ sai bằng cách viết đúng, áp cho mọi chương khi đọc và nghe.
class WordFixScreen extends ConsumerStatefulWidget {
  const WordFixScreen({super.key});

  @override
  ConsumerState<WordFixScreen> createState() => _WordFixScreenState();
}

class _WordFixScreenState extends ConsumerState<WordFixScreen> {
  List<(String, String)> _fixes = const [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final fixes = await ref.read(appDbProvider).getWordFixes();
    if (mounted) {
      setState(() {
        _fixes = fixes;
        _loaded = true;
      });
    }
  }

  Future<void> _save(List<(String, String)> fixes) async {
    await ref.read(appDbProvider).setWordFixes(fixes);
    await _load();
  }

  // Hộp thoại thêm/sửa một cặp: [existing] null là thêm mới. Lưu qua helper
  // dùng chung (xem showWordFixEditor), xong nạp lại danh sách.
  Future<void> _openEditor({(String, String)? existing}) async {
    final ok = await showWordFixEditor(
      context,
      ref.read(appDbProvider),
      initialWrong: existing?.$1,
      initialRight: existing?.$2,
    );
    if (ok) await _load();
  }

  Future<void> _delete(int index) async {
    final target = _fixes[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá cụm từ?'),
        content: Text('"${target.$1}" sẽ không còn được tự thay nữa.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _save([..._fixes]..removeAt(index));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Sửa lỗi từ truyện')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'Nguồn truyện đôi khi chèn nhầm khoảng trắng giữa từ '
              '("gi ết", "thi th ể"). Thêm cụm từ sai và cách viết đúng — '
              'app tự thay khi đọc hoặc nghe, kể cả chương đã tải sẵn. '
              'Khớp nguyên văn, phân biệt hoa thường.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : _fixes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.spellcheck_outlined,
                            size: 64,
                            color: theme.colorScheme.outline,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Chưa có cụm từ nào',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Bấm nút "+" để thêm cụm từ sai gặp được '
                            'khi đọc, kèm cách viết đúng của nó.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      for (var i = 0; i < _fixes.length; i++)
                        ListTile(
                          title: Text(
                            _fixes[i].$1,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '→ ${_fixes[i].$2}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            tooltip: 'Xoá',
                            onPressed: () => _delete(i),
                          ),
                          onTap: () => _openEditor(existing: _fixes[i]),
                        ),
                    ],
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('Thêm cụm từ'),
      ),
    );
  }
}

/// Mở hộp thoại thêm/sửa một cụm từ sửa lỗi và LƯU NGAY vào DB. Dùng chung
/// cho màn quản lý (tab Cài đặt) và nút "Đổi từ" khi bôi đen text ở màn đọc.
/// Trả về true nếu đã lưu — nơi gọi nên áp lại bản sửa cho nội dung đang mở.
Future<bool> showWordFixEditor(
  BuildContext context,
  AppDb db, {
  String? initialWrong,
  String? initialRight,
}) async {
  final fixes = await db.getWordFixes();
  if (!context.mounted) return false;
  final result = await showDialog<(String, String)>(
    context: context,
    builder: (_) => _FixDialog(
      initialWrong: initialWrong,
      initialRight: initialRight,
      fixes: fixes,
      isEdit: initialWrong != null && initialRight != null,
    ),
  );
  if (result == null) return false;
  final next = [...fixes];
  final at = initialWrong == null
      ? -1
      : next.indexWhere((f) => f.$1 == initialWrong);
  if (at >= 0) {
    next[at] = result;
  } else {
    next.add(result);
  }
  await db.setWordFixes(next);
  return true;
}

/// Hộp thoại nhập cặp (sai → đúng). StatefulWidget tự giữ controller: pop về
/// thì dialog còn chạy animation thoát và vẫn build TextFields — dispose
/// controller ngay lúc showDialog trả về là "used after being disposed";
/// dispose() của State được gọi đúng lúc route gỡ hẳn khỏi màn hình.
class _FixDialog extends StatefulWidget {
  final String? initialWrong;
  final String? initialRight;
  final List<(String, String)> fixes;
  final bool isEdit;

  const _FixDialog({
    required this.initialWrong,
    required this.initialRight,
    required this.fixes,
    required this.isEdit,
  });

  @override
  State<_FixDialog> createState() => _FixDialogState();
}

class _FixDialogState extends State<_FixDialog> {
  late final TextEditingController _wrongCtrl = TextEditingController(
    text: widget.initialWrong ?? '',
  );
  late final TextEditingController _rightCtrl = TextEditingController(
    text: widget.initialRight ?? '',
  );
  String? _error;

  void _submit() {
    final wrong = _wrongCtrl.text;
    if (wrong.trim().isEmpty) {
      setState(() => _error = 'Cụm từ sai không được để trống');
      return;
    }
    // Cụm từ sai là khoá của dòng (mỗi dòng một cụm từ riêng): khi sửa, bỏ
    // chính dòng đang sửa ra khỏi phép kiểm tra trùng.
    final duplicate = widget.fixes.any(
      (f) => f.$1 == wrong && f.$1 != widget.initialWrong,
    );
    if (duplicate) {
      setState(() => _error = 'Cụm từ này đã có trong danh sách');
      return;
    }
    Navigator.pop(context, (wrong, _rightCtrl.text));
  }

  @override
  void dispose() {
    _wrongCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.isEdit ? 'Sửa cụm từ' : 'Thêm cụm từ'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _wrongCtrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Cụm từ sai trong truyện',
              hintText: 'gi ết',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _rightCtrl,
            decoration: const InputDecoration(
              labelText: 'Thay bằng',
              hintText: 'giết',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Huỷ'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Lưu')),
      ],
    );
  }
}
