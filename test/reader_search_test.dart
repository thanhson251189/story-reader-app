import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/reader/reader_screen.dart';

void main() {
  test('paragraphMatches: tìm không dấu vẫn khớp chữ có dấu', () {
    expect(
      ReaderScreen.paragraphMatches('Hắn vặn nấc công lực lên mức tối đa.', 'van nac'),
      isTrue,
    );
    expect(
      ReaderScreen.paragraphMatches('Lý Tằng Kinh nhìn quanh.', 'ly tang'),
      isTrue,
    );
    expect(
      ReaderScreen.paragraphMatches('Không có gì ở đây.', 'vàng'),
      isFalse,
    );
  });

  test('paragraphMatches: từ khoá rỗng thì không khớp gì', () {
    expect(ReaderScreen.paragraphMatches('Bất kỳ đoạn nào', ''), isFalse);
    expect(ReaderScreen.paragraphMatches('Bất kỳ đoạn nào', '   '), isFalse);
  });

  test('paragraphMatches: hoa thường không ảnh hưởng', () {
    expect(
      ReaderScreen.paragraphMatches('Chu Cơ Diễm liếc nhìn.', 'chu cơ'),
      isTrue,
    );
    expect(
      ReaderScreen.paragraphMatches('chu cơ diễm liếc nhìn.', 'CHU CƠ'),
      isTrue,
    );
  });
}
