import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/models.dart';

void main() {
  test('storyUrlFromChapter suy URL truyện từ URL chương', () {
    expect(
      storyUrlFromChapter('https://x.test/truyen/chuong-1'),
      'https://x.test/truyen',
    );
    // Dấu slash cuối không cắt nhầm vào tên chương.
    expect(
      storyUrlFromChapter('https://x.test/truyen/chuong-1/'),
      'https://x.test/truyen/',
    );
    expect(storyUrlFromChapter('book:abc:5'), 'book:abc');
    expect(storyUrlFromChapter('book:abc'), 'book:abc');
  });

  test('storyUrlFromChapter với URL rác trả nguyên xi, không ném', () {
    // Uri.tryParse trả null cho authority hỏng — đường gọi dùng kết quả cho
    // touchLibrary/tìm mục lục nên phải trả gì đó thay vì exception.
    expect(storyUrlFromChapter('http://['), 'http://[');
  });

  test('adapter đọc paragraphBreak và dọn tiêu đề bằng titleCleanup', () {
    final a = SourceAdapter.fromJson({
      'domain': 'x.test',
      'paragraphBreak': 'line',
      'titleCleanup': [
        {'pattern': r'^\d+\s+', 'replacement': ''},
      ],
    });
    expect(a.paragraphBreak, 'line');
    expect(a.cleanTitle('2 Chương 2: Gặp gỡ'), 'Chương 2: Gặp gỡ');
    // titleCleanup không được rò sang nội dung chương.
    expect(a.clean('2 đoạn văn'), '2 đoạn văn');
  });
}
