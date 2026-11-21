import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/local/book_importer.dart';

void main() {
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
}
