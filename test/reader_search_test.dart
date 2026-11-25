import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/reader/reader_screen.dart';

void main() {
  test('paragraphMatches: tìm không dấu vẫn khớp chữ có dấu', () {
    expect(
      ReaderScreen.paragraphMatches(
        'Hắn vặn nấc công lực lên mức tối đa.',
        'van nac',
      ),
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

  test('paragraphMatches: không khớp bên trong từ dài hơn', () {
    // "Ngũ" fold thành "ngu", là tiền tố của "người" ("nguoi"). Khớp chuỗi con
    // thì tô nhầm hàng chục chữ "người" khi user tìm đúng từ vừa bôi đen.
    expect(ReaderScreen.paragraphMatches('có người đứng đó.', 'Ngũ'), isFalse);
    expect(ReaderScreen.paragraphMatches('có người đứng đó.', 'ngu'), isFalse);
    expect(ReaderScreen.paragraphMatches('thấy Ngũ rồi đi.', 'Ngũ'), isTrue);
    expect(ReaderScreen.paragraphMatches('thấy Ngũ, rồi đi.', 'Ngũ'), isTrue);
    expect(ReaderScreen.paragraphMatches('Ngũ', 'Ngũ'), isTrue);
    expect(ReaderScreen.paragraphMatches('chương 150', '15'), isFalse);
    expect(ReaderScreen.paragraphMatches('chương 15.', '15'), isTrue);
  });

  test(
    'paragraphMatches: từ khoá nhiều dòng vẫn khớp đoạn đã dẹp khoảng trắng',
    () {
      expect(
        ReaderScreen.paragraphMatches('Ngũ Hành đại đế đứng đó.', 'Ngũ\nHành'),
        isTrue,
      );
      expect(
        ReaderScreen.paragraphMatches(
          'Ngũ Hành đại đế đứng đó.',
          'Ngũ\n\nHành',
        ),
        isTrue,
      );
    },
  );

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

  test(
    'highlightSpans: từ khoá rỗng hoặc không khớp thì 1 span nguyên văn',
    () {
      for (final q in ['', '   ', 'khongco']) {
        final spans = ReaderScreen.highlightSpans(
          'Nguyên văn một đoạn.',
          q,
          base(),
          hl(),
        );
        expect(spans.length, 1);
        expect(spans.single.text, 'Nguyên văn một đoạn.');
        expect(spans.single.style!.backgroundColor, isNull);
      }
    },
  );

  test('highlightSpans: chỉ tô từ trọn, không tô phần đầu của từ dài hơn', () {
    final spans = ReaderScreen.highlightSpans(
      'có Ngũ người đứng.',
      'Ngũ',
      base(),
      hl(),
    );
    expect(matched(spans), ['Ngũ']);
    expect(plain(spans).join(), 'có  người đứng.');
  });

  test('highlightSpans: từ khoá nhiều dòng vẫn tô cụm đã dẹp khoảng trắng', () {
    final spans = ReaderScreen.highlightSpans(
      'Ngũ Hành đại đế.',
      'Ngũ\nHành',
      base(),
      hl(),
    );
    expect(matched(spans), ['Ngũ Hành']);
  });

  test(
    'highlightSpans: span khớp dài đúng bằng từ khoá, không ăn vào từ dài hơn',
    () {
      final spans = ReaderScreen.highlightSpans(
        'Đẹp hơn tại đeps hơn tại.',
        'dep',
        base(),
        hl(),
      );
      // "đeps" chứa "đep" nhưng không phải từ trọn — không tô.
      expect(matched(spans), ['Đẹp']);
      expect(plain(spans), [' hơn tại đeps hơn tại.']);
    },
  );

  test('bookmarkParagraphIndex lấy đoạn đang chạm, không phải lần xuất hiện đầu', () {
    const paras = ['anh nói ở đầu', 'đoạn giữa', 'anh nói ở cuối'];
    expect(
      ReaderScreen.bookmarkParagraphIndex(paras, 'anh nói', pressedIndex: 2),
      2,
    );
    expect(ReaderScreen.bookmarkParagraphIndex(paras, 'anh nói'), 0);
  });

  test('shorterThanCached giữ chương dài khi trang trả bản cụt', () {
    final full = ChapterContent(
      url: 'https://x.test/c',
      title: 'C',
      paragraphs: [List.filled(500, 'a').join()],
    );
    final stub = ChapterContent(
      url: 'https://x.test/c',
      title: 'C',
      paragraphs: const ['đăng nhập để đọc tiếp'],
    );
    final edited = ChapterContent(
      url: 'https://x.test/c',
      title: 'C',
      paragraphs: [List.filled(400, 'b').join()],
    );
    expect(ReaderScreen.shorterThanCached(full, stub), isTrue);
    expect(ReaderScreen.shorterThanCached(full, edited), isFalse);
    expect(ReaderScreen.shorterThanCached(stub, full), isFalse);
  });

  test('atTocEnd: chương cuối mục lục mới hiện nút kiểm tra', () {
    // Có mục lục: tin vị trí, kể cả khi trang còn nút chương sau (mục lục cũ).
    expect(
      ReaderScreen.atTocEnd(tocIndex: 740, tocTotal: 741, hasNext: false),
      isTrue,
    );
    expect(
      ReaderScreen.atTocEnd(tocIndex: 740, tocTotal: 741, hasNext: true),
      isTrue,
      reason: 'vị trí trong mục lục là nguồn tin cậy hơn nút trên trang',
    );
    expect(
      ReaderScreen.atTocEnd(tocIndex: 5, tocTotal: 741, hasNext: false),
      isFalse,
      reason: 'còn chương sau trong mục lục thì không phải cuối truyện',
    );
    // Chưa có mục lục (hoặc chương không khớp mục lục): dựa vào nút chương sau.
    expect(
      ReaderScreen.atTocEnd(tocIndex: null, tocTotal: null, hasNext: false),
      isTrue,
    );
    expect(
      ReaderScreen.atTocEnd(tocIndex: null, tocTotal: 741, hasNext: true),
      isFalse,
    );
  });
}
