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
  BookImporter(this.db);

  Future<BookImportResult> importFile(String path) async {
    final bytes = await File(path).readAsBytes();
    final ext = p.extension(path).toLowerCase().replaceFirst('.', '');
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
