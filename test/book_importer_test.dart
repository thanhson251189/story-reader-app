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
}
