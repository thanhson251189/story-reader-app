import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/library/library_screen.dart';

void main() {
  test('newBadge: chưa check chương mới thì không hiện', () {
    expect(LibraryScreen.newBadge(null, null, 'https://x/chuong-1029'), null);
  });

  test('newBadge: đã đọc tới chương mới nhất thì ẩn', () {
    expect(
      LibraryScreen.newBadge(
        'https://x/chuong-1035',
        'T',
        'https://x/chuong-1035',
      ),
      null,
    );
  });

  test('newBadge: có chương mới hơn chương đang đọc', () {
    expect(
      LibraryScreen.newBadge(
        'https://x/chuong-1035',
        'T',
        'https://x/chuong-1029',
      ),
      'Mới: Chương 1035',
    );
  });

  test('newBadge: URL không đánh số thì dùng tiêu đề', () {
    expect(
      LibraryScreen.newBadge('https://x/abc', 'Thiên chương', 'https://x/old'),
      'Mới: Thiên chương',
    );
  });
}
