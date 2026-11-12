import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/fetcher/web_fetcher.dart';
import 'package:story_reader/reader/toc_screen.dart';

void main() {
  test('chapterLabel ghép số chương, không lặp nhãn có sẵn', () {
    expect(TocScreen.chapterLabel('Học Giáo', 2), 'Chương 2: Học Giáo');
    expect(TocScreen.chapterLabel('02\nHọc Giáo', 2), 'Chương 2: Học Giáo');
    expect(TocScreen.chapterLabel('365 Ngày', 7), 'Chương 7: 365 Ngày');
    expect(TocScreen.chapterLabel('', 3), 'Chương 3');
    expect(TocScreen.chapterLabel('Chương I: Mở đầu', 1), 'Chương I: Mở đầu');
    expect(TocScreen.chapterLabel('chapter 5: X', 5), 'chapter 5: X');
  });

  test('fold bỏ dấu tiếng Việt để lọc không dấu', () {
    expect(TocScreen.fold('Đại Thánh'), 'dai thanh');
    expect(TocScreen.fold('Chương 1029'), 'chuong 1029');
    expect(TocScreen.fold('ĐƯỜng'), 'duong');
  });

  test('trailingNumber lấy số đuôi URL chương', () {
    expect(
      WebFetcher.trailingNumber('https://x.com/doc-truyen/a/chuong-1035'),
      1035,
    );
    expect(WebFetcher.trailingNumber('https://x.com/khong-so'), null);
  });
}