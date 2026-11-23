import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/local/book_importer.dart';
import 'package:story_reader/local/local_book.dart';

void main() {
  setUpAll(() async {
    // Test nhập sách chạm DB thật; compute() chạy isolate riêng nên FFI phải
    // sẵn trong isolate chính trước khi importFile chạy.
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('BookImporter chặn sớm đuôi không hỗ trợ, không đọc file', () async {
    // File không tồn tại: nếu guard đọc file trước khi kiểm tra đuôi thì
    // test này lỗi IO thay vì FormatException.
    expect(
      BookImporter(AppDb()).importFile('khong-ton-tai.pdf'),
      throwsFormatException,
    );
  });

  test('BookImporter vẫn nhận các đuôi được khai báo', () async {
    // Đuôi hợp lệ vượt qua guard rồi mới lỗi IO (file không tồn tại).
    expect(
      BookImporter(AppDb()).importFile('khong-ton-tai.epub'),
      throwsA(isNot(isA<FormatException>())),
    );
  });

  test('BookImporter chặn file quá lớn trước khi đọc vào bộ nhớ', () async {
    final dir = await Directory.systemTemp.createTemp('book_size_test');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/to.txt';
    await File(path).writeAsString('nội dung nhỏ');
    // Hạn mức chỉ 4 byte: file 12 byte đã phải bị chặn ở bước đo kích thước,
    // không đọc nội dung — mô phỏng đúng chỗ chặn file hàng trăm MB.
    await expectLater(
      BookImporter(AppDb(), maxBytes: 4).importFile(path),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains('quá lớn'),
        ),
      ),
    );
  });

  test('Nhập TXT qua isolate riêng: mục lục, cache và thư viện đủ', () async {
    final dir = await Directory.systemTemp.createTemp('book_iso_test');
    addTearDown(() => dir.delete(recursive: true));
    // Khối dài hơn 3000 ký tự để bộ tách đoạn cắt theo dòng: tiêu đề "Chương N"
    // đứng riêng thành một đoạn và được nhận là đầu chương.
    final path = '${dir.path}/sach thu.txt';
    await File(path).writeAsString(
      'Chương 1\n${'Nội dung chương một. ' * 200}\n\n'
      'Chương 2\n${'Nội dung chương hai. ' * 200}\n',
    );
    final db = AppDb(fileName: 'book_importer_iso_test.db');
    final result = await BookImporter(db).importFile(path);
    expect(result.chapters, 2);
    final toc = await db.getToc(result.storyUrl);
    expect(toc.map((c) => c.title), ['Chương 1', 'Chương 2']);
    final first = await db.getCachedChapter('${result.storyUrl}:0');
    expect(first!.paragraphs.join(' '), contains('chương một'));
    final last = await db.getCachedChapter('${result.storyUrl}:1');
    expect(last!.paragraphs.join(' '), contains('chương hai'));
    final lib = await db.getLibrary();
    expect(
      lib.where((e) => e['story_url'] == result.storyUrl),
      hasLength(1),
    );
  });

  test('TXT tách "Chương 1 Tên" không cần dấu hai chấm', () {
    final book = LocalBook.txt(
      Uint8List.fromList(
        utf8.encode(
          'Chương 1 Mở đầu\n'
          'Nội dung một.\n'
          '\n'
          'Chương 2 Tiếp theo\n'
          'Nội dung hai.\n',
        ),
      ),
      'truyen.txt',
    );
    expect(book.chapters.map((c) => c.title), [
      'Chương 1 Mở đầu',
      'Chương 2 Tiếp theo',
    ]);
    expect(book.chapters[0].paragraphs, ['Nội dung một.']);
    expect(book.chapters[1].paragraphs, ['Nội dung hai.']);
  });

  test('TXT không coi câu thường bắt đầu bằng Chương là đầu chương', () {
    final book = LocalBook.txt(
      Uint8List.fromList(
        utf8.encode('Chương trình hôm nay rất dài và không có số.\n\nHết.\n'),
      ),
      'khong-chuong.txt',
    );
    expect(book.chapters, hasLength(1));
  });
}
