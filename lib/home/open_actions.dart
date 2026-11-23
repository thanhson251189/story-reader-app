import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/errors.dart';
import '../data/app_db.dart';
import '../local/book_importer.dart';
import '../reader/reader_screen.dart';

/// Link web đủ để mở chương: có scheme và tên miền. Link sách trong máy
/// (`book:`) đi đường khác.
bool isWebChapterLink(String raw) {
  final u = raw.trim();
  if (u.isEmpty || u.startsWith('book:')) return false;
  final uri = Uri.tryParse(u);
  return uri != null && uri.hasScheme && uri.host.contains('.');
}

Future<void> openWebLink(BuildContext context, String raw) async {
  final u = raw.trim();
  if (u.startsWith('book:')) {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderScreen(url: u)),
    );
    return;
  }
  if (!isWebChapterLink(u)) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Link không hợp lệ, dán link chương đầy đủ (https://...)',
        ),
      ),
    );
    return;
  }
  await Navigator.push(
    context,
    MaterialPageRoute(builder: (_) => ReaderScreen(url: u)),
  );
}

Future<void> showPasteLinkDialog(BuildContext context) async {
  final ctrl = TextEditingController();
  final url = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Dán link chương'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: InputDecoration(
          hintText: 'https://...',
          suffixIcon: IconButton(
            tooltip: 'Dán',
            icon: const Icon(Icons.content_paste),
            onPressed: () async {
              final data = await Clipboard.getData(Clipboard.kTextPlain);
              if (data?.text != null) ctrl.text = data!.text!;
            },
          ),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('Mở'),
        ),
      ],
    ),
  );
  ctrl.dispose();
  if (url == null || !context.mounted) return;
  await openWebLink(context, url);
}

/// Chọn file EPUB/MOBI/FB2/TXT, nhập vào máy, rồi mở chương đầu.
/// Hộp thoại chặn thao tác lúc đang đọc file — file lớn trên máy yếu mất vài giây.
Future<void> pickAndImportBook(BuildContext context, AppDb db) async {
  PlatformFile? picked;
  try {
    picked = await FilePicker.pickFile(type: FileType.any);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Không mở được trình chọn file: $e')),
      );
    }
    return;
  }
  final path = picked?.path;
  if (path == null || !context.mounted) return;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Expanded(child: Text('Đang nhập sách...')),
          ],
        ),
      ),
    ),
  );
  try {
    final result = await BookImporter(db).importFile(path);
    if (context.mounted) Navigator.of(context).pop();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Đã nhập "${result.title}" (${result.chapters} chương)'),
      ),
    );
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderScreen(url: '${result.storyUrl}:0'),
      ),
    );
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Nhập sách lỗi: ${friendlyError(e)}')),
      );
    }
  }
}
