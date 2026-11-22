import 'package:flutter/material.dart';
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

  TextStyle base() => const TextStyle(fontSize: 16);
  TextStyle hl() => base().copyWith(backgroundColor: const Color(0x66FFB74D));

  List<String> plain(List<TextSpan> spans) => [
    for (final s in spans)
      if (s.style?.backgroundColor == null) s.text!,
  ];
  List<String> matched(List<TextSpan> spans) => [
    for (final s in spans)
      if (s.style?.backgroundColor != null) s.text!,
  ];

  test('highlightSpans: tô đúng các chỗ khớp, phần còn lại giữ nguyên', () {
    final spans = ReaderScreen.highlightSpans(
      'Hắn chém một kiếm, chém thêm lần nữa.',
      'chém',
      base(),
      hl(),
    );
    expect(plain(spans), ['Hắn ', ' một kiếm, ', ' thêm lần nữa.']);
    expect(matched(spans), ['chém', 'chém']);
  });

  test('highlightSpans: tìm không dấu vẫn tô đúng chữ có dấu', () {
    final spans = ReaderScreen.highlightSpans(
      'Chém giết trong chém giết.',
      'chem giet',
      base(),
      hl(),
    );
    // Cả 2 chỗ khớp trong đoạn đều được tô.
    expect(matched(spans), ['Chém giết', 'chém giết']);
    expect(plain(spans), [' trong ', '.']);
  });

  test('highlightSpans: từ khoá rỗng hoặc không khớp thì 1 span nguyên văn', () {
    for (final q in ['', '   ', 'khongco']) {
      final spans = ReaderScreen.highlightSpans('Nguyên văn một đoạn.', q, base(), hl());
      expect(spans.length, 1);
      expect(spans.single.text, 'Nguyên văn một đoạn.');
      expect(spans.single.style!.backgroundColor, isNull);
    }
  });

  test('highlightSpans: span khớp dài đúng bằng từ khoá (fold 1-1)', () {
    final spans = ReaderScreen.highlightSpans('Đẹp hơn tại đeps hơn tại.', 'dep', base(), hl());
    // Khớp thứ hai nằm trong "đeps" — chỉ tô đúng 3 ký tự bằng độ dài từ khoá.
    expect(matched(spans), ['Đẹp', 'đep']);
    expect(plain(spans), [' hơn tại ', 's hơn tại.']);
  });
}
