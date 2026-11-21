import 'dart:io';
import 'dart:math';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/models.dart';
import '../data/app_db.dart';
import 'local_book.dart';

class BookImportResult {
  final String storyUrl;
  final String title;
  final int chapters;
  const BookImportResult(this.storyUrl, this.title, this.chapters);
}

class BookImporter {
  final AppDb db;

  /// Giới hạn kích thước file nhập: app đọc cả file vào bộ nhớ, file hàng
  /// trăm MB trên máy RAM thấp là treo/sập. Sách chữ thật hiếm khi quá vài
  /// chục MB. Truyền maxBytes nhỏ hơn trong test.
  final int maxBytes;

  static const maxImportBytes = 50 * 1024 * 1024;
  static const _mb = 1024 * 1024;

  BookImporter(this.db, {this.maxBytes = maxImportBytes});

  Future<BookImportResult> importFile(String path) async {
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    // Chặn sớm trước khi đọc cả file vào bộ nhớ (FilePicker cho chọn loại nào).
    if (!LocalBook.formats.contains(ext)) {
      throw FormatException(
        'Chưa hỗ trợ .$ext — chỉ đọc được EPUB, MOBI, FB2, TXT',
      );
    }
    final file = File(path);
    final size = await file.length();
    if (size > maxBytes) {
      throw FormatException(
        'File quá lớn (${(size / _mb).toStringAsFixed(0)}MB) — app đọc được '
        'tối đa ${(maxBytes / _mb).round()}MB. Hãy chia nhỏ file hoặc chuyển '
        'đổi sang EPUB.',
      );
    }
    final bytes = await file.readAsBytes();
    final name = p.basenameWithoutExtension(path);
    final book = await LocalBook.parse(ext, bytes, name);
    if (book.chapters.isEmpty) throw FormatException('Không đọc được nội dung sách');

    final id = _newId();
    String? coverPath;
    if (book.cover != null) {
      try {
        final dir = Directory(p.join((await getApplicationSupportDirectory()).path, 'covers'));
        await dir.create(recursive: true);
        coverPath = p.join(dir.path, '$id.png');
        await File(coverPath).writeAsBytes(img.encodePng(book.cover!));
      } catch (_) {
        coverPath = null;
      }
    }

    final storyUrl = 'book:$id';
    final refs = <ChapterRef>[];
    final chapters = <ChapterContent>[];
    for (var i = 0; i < book.chapters.length; i++) {
      final ch = book.chapters[i];
      final url = '$storyUrl:$i';
      refs.add(ChapterRef(title: ch.title, url: url));
      chapters.add(ChapterContent(
        url: url,
        title: ch.title,
        paragraphs: ch.paragraphs,
        nextUrl: i + 1 < book.chapters.length ? '$storyUrl:${i + 1}' : null,
        prevUrl: i > 0 ? '$storyUrl:${i - 1}' : null,
      ));
    }

    await db.cacheChapters(chapters);
    await db.saveToc(storyUrl, refs);
    await db.upsertLibrary(
      storyUrl: storyUrl,
      title: book.title,
      coverUrl: coverPath,
      lastChapterUrl: '$storyUrl:0',
    );
    return BookImportResult(storyUrl, book.title, book.chapters.length);
  }

  static String _newId() {
    final r = Random();
    final rand = List.generate(4, (_) => r.nextInt(1296).toRadixString(36)).join();
    return '${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}$rand';
  }
}
