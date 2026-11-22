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
}
