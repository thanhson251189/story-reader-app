import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/providers.dart';
import '../data/app_db.dart';

/// Màn quản lý danh sách từ/cụm từ sửa lỗi: nguồn truyện đôi khi chèn nhầm
/// khoảng trắng giữa các ký tự ("gi ết", "thi th ể") — người dùng dạy app
/// thay cụm từ sai bằng cách viết đúng, khi đọc và nghe.
class WordFixScreen extends ConsumerStatefulWidget {
  const WordFixScreen({super.key});

  @override
  ConsumerState<WordFixScreen> createState() => _WordFixScreenState();
}

class _WordFixScreenState extends ConsumerState<WordFixScreen> {
  List<WordFix> _fixes = const [];
  Map<String, String> _titles = const {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = ref.read(appDbProvider);
    final fixes = await db.getWordFixes();
    final rows = await db.getLibrary();
    if (!mounted) return;
    setState(() {
      _fixes = fixes;
      _titles = {
        for (final row in rows)
          if (row['story_url'] is String && row['title'] is String)
            row['story_url'] as String: row['title'] as String,
      };
      _loaded = true;
    });
  }

  Future<void> _save(List<WordFix> fixes) async {
    await ref.read(appDbProvider).setWordFixes(fixes);
    await _load();
  }

  String _scopeLabel(WordFix fix) {
    final url = fix.storyUrl;
    if (url == null) return 'Mọi truyện';
    return _titles[url] ?? 'Chỉ một truyện';
  }

  // Hộp thoại thêm/sửa một cặp. Thêm mới ở đây luôn là mọi truyện — phạm vi
  // "chỉ truyện này" chỉ chọn được lúc đang đọc. Sửa thì giữ phạm vi cũ.
  Future<void> _openEditor({WordFix? existing}) async {
    final ok = await showWordFixEditor(
      context,
      ref.read(appDbProvider),
      initialWrong: existing?.from,
      initialRight: existing?.to,
      initialStoryUrl: existing?.storyUrl,
      scopeLabel: existing == null ? 'Mọi truyện' : _scopeLabel(existing),
    );
    if (ok) await _load();
  }

  Future<void> _delete(int index) async {
    final target = _fixes[index];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xoá cụm từ?'),
        content: Text('"${target.from}" sẽ không còn được tự thay nữa.'),
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
              'Cụm từ thêm ở đây áp cho mọi truyện. Cụm từ dạy lúc đang đọc '
              'có thể chỉ áp một truyện — dòng đó ghi tên truyện bên dưới. '
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
                            _fixes[i].from,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '→ ${_fixes[i].to}\n${_scopeLabel(_fixes[i])}',
                            maxLines: 3,
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
/// [storyChoice] khác null thì cho chọn "chỉ truyện này" (mặc định) hoặc mọi
/// truyện — đó là đường từ màn đọc. Không truyền thì giữ [initialStoryUrl]
/// (thêm mới từ Cài đặt là mọi truyện). Trả về true nếu đã lưu.
Future<bool> showWordFixEditor(
  BuildContext context,
  AppDb db, {
  String? initialWrong,
  String? initialRight,
  String? initialStoryUrl,
  String? scopeLabel,
  String? storyChoice,
  String? storyLabel,
}) async {
  final fixes = await db.getWordFixes();
  if (!context.mounted) return false;
  final choice = (storyChoice == null || storyChoice.isEmpty)
      ? null
      : storyChoice;
  final result = await showDialog<WordFix>(
    context: context,
    builder: (_) => _FixDialog(
      initialWrong: initialWrong,
      initialRight: initialRight,
      initialStoryUrl: initialStoryUrl,
      fixes: fixes,
      isEdit: initialWrong != null && initialRight != null,
      scopeLabel: scopeLabel,
      storyChoice: choice,
      storyLabel: storyLabel,
    ),
  );
  if (result == null) return false;
  final next = [...fixes];
  // Sửa từ Cài đặt: thay đúng dòng cũ, kể cả khi cụm từ sai bị đổi chữ.
  // Thêm mới (kể cả từ màn đọc): chỉ đè dòng cùng cụm từ VÀ cùng phạm vi,
  // không biến mục chung thành mục của một truyện.
  var at = -1;
  if (initialWrong != null && initialRight != null) {
    at = next.indexWhere(
      (f) => f.from == initialWrong && f.sameScope(initialStoryUrl),
    );
  }
  if (at < 0) {
    at = next.indexWhere(
      (f) => f.from == result.from && f.sameScope(result.storyUrl),
    );
  }
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
  final String? initialStoryUrl;
  final List<WordFix> fixes;
  final bool isEdit;
  final String? scopeLabel;
  final String? storyChoice;
  final String? storyLabel;

  const _FixDialog({
    required this.initialWrong,
    required this.initialRight,
    required this.initialStoryUrl,
    required this.fixes,
    required this.isEdit,
    required this.scopeLabel,
    required this.storyChoice,
    required this.storyLabel,
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
  // Màn đọc: mặc định chỉ truyện đang đọc, không phải mọi truyện.
  bool _onlyThisStory = true;

  String? get _scope => widget.storyChoice == null
      ? widget.initialStoryUrl
      : (_onlyThisStory ? widget.storyChoice : null);

  void _submit() {
    final wrong = _wrongCtrl.text;
    if (wrong.trim().isEmpty) {
      setState(() => _error = 'Cụm từ sai không được để trống');
      return;
    }
    final scope = _scope;
    // Trùng = cùng cụm từ sai và cùng phạm vi. Dòng đang sửa, hoặc cụm từ
    // màn đọc điền sẵn, được lưu đè — không báo trùng.
    final duplicate = widget.fixes.any((f) {
      if (f.from != wrong || !f.sameScope(scope)) return false;
      if (widget.initialWrong == wrong &&
          (widget.storyChoice != null || f.sameScope(widget.initialStoryUrl))) {
        return false;
      }
      return true;
    });
    if (duplicate) {
      setState(() => _error = 'Cụm từ này đã có trong danh sách');
      return;
    }
    Navigator.pop(context, WordFix(wrong, _rightCtrl.text, storyUrl: scope));
  }

  @override
  void dispose() {
    _wrongCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.isEdit ? 'Sửa cụm từ' : 'Thêm cụm từ'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
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
            const SizedBox(height: 12),
            if (widget.storyChoice != null)
              RadioGroup<bool>(
                groupValue: _onlyThisStory,
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _onlyThisStory = v);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<bool>(
                      value: true,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text('Chỉ truyện này'),
                      subtitle: widget.storyLabel == null
                          ? null
                          : Text(
                              widget.storyLabel!,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                    ),
                    const RadioListTile<bool>(
                      value: false,
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: Text('Mọi truyện'),
                    ),
                  ],
                ),
              )
            else
              Text(
                'Áp dụng cho: ${widget.scopeLabel ?? 'Mọi truyện'}',
                style: theme.textTheme.bodySmall,
              ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Huỷ'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Lưu')),
      ],
    );
  }
}
