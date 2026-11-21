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

  test('matchesQuery: tìm không dấu vẫn khớp tên có dấu', () {
    expect(
      LibraryScreen.matchesQuery(item('Đại Đường Song Long'), 'song long'),
      isTrue,
    );
    expect(LibraryScreen.matchesQuery(item('Vạn Cổ Thần Đế'), 'van co'), isTrue);
    expect(LibraryScreen.matchesQuery(item('Đại Đường'), 'nhật ký'), isFalse);
  });

  test('matchesQuery: query rỗng thì khớp hết', () {
    expect(LibraryScreen.matchesQuery(item('Bất kỳ'), ''), isTrue);
    expect(LibraryScreen.matchesQuery(item('Bất kỳ'), '   '), isTrue);
  });

  test('hasNew: đúng với badge chương mới', () {
    expect(
      LibraryScreen.hasNew(item('A', latest: 'https://x/2', last: 'https://x/1')),
      isTrue,
    );
    expect(
      LibraryScreen.hasNew(item('A', latest: 'https://x/2', last: 'https://x/2')),
      isFalse,
    );
    expect(LibraryScreen.hasNew(item('A')), isFalse);
  });
}

Map<String, dynamic> item(
  String title, {
  String? latest,
  String? last,
}) => {
  'title': title,
  'latest_chapter_url': latest,
  'latest_chapter_title': null,
  'last_chapter_url': last,
};
