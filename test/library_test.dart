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

  test(
    'newBadge: link lệch slash cuối hoặc hoa thường không phải chương mới',
    () {
      expect(
        LibraryScreen.newBadge(
          'https://x/chuong-1035/',
          'T',
          'https://x/chuong-1035',
        ),
        null,
      );
      expect(
        LibraryScreen.newBadge(
          'https://X/chuong-1035#doc',
          'T',
          'http://x/chuong-1035',
        ),
        null,
      );
    },
  );

  test('newBadge: có chương mới hơn chương đang đọc', () {
    expect(
      LibraryScreen.newBadge(
        'https://x/chuong-1035',
        'T',
        'https://x/chuong-1029',
      ),
      'Chưa đọc: Chương 1035',
    );
  });

  test('newBadge: URL không đánh số thì dùng tiêu đề', () {
    expect(
      LibraryScreen.newBadge('https://x/abc', 'Thiên chương', 'https://x/old'),
      'Chưa đọc: Thiên chương',
    );
  });

  test('matchesQuery: tìm không dấu vẫn khớp tên có dấu', () {
    expect(
      LibraryScreen.matchesQuery(item('Đại Đường Song Long'), 'song long'),
      isTrue,
    );
    expect(
      LibraryScreen.matchesQuery(item('Vạn Cổ Thần Đế'), 'van co'),
      isTrue,
    );
    expect(LibraryScreen.matchesQuery(item('Đại Đường'), 'nhật ký'), isFalse);
  });

  test('matchesQuery: query rỗng thì khớp hết', () {
    expect(LibraryScreen.matchesQuery(item('Bất kỳ'), ''), isTrue);
    expect(LibraryScreen.matchesQuery(item('Bất kỳ'), '   '), isTrue);
  });

  test('sourceLabel: domain của nguồn, sách trong máy thì ghi rõ', () {
    expect(
      LibraryScreen.sourceLabel(
        'https://truyendich.vn/kiem-dao/chapter-5/',
        adapterDomain: 'truyendich.vn',
      ),
      'truyendich.vn',
    );
    expect(
      LibraryScreen.sourceLabel('http://truyendich.us/truyen/x/'),
      'truyendich.us',
    );
    expect(
      LibraryScreen.sourceLabel(
        'https://x.example.com/truyen',
        adapterDomain: 'example.com',
      ),
      'example.com',
      reason: 'adapter đã cài là nguồn tin cậy hơn host trong link',
    );
    expect(LibraryScreen.sourceLabel('book:abc123'), 'Sách trong máy');
    expect(LibraryScreen.sourceLabel('không phải link'), '');
  });

  test('hasNew: đúng với badge chương mới', () {
    expect(
      LibraryScreen.hasNew(
        item('A', latest: 'https://x/2', last: 'https://x/1'),
      ),
      isTrue,
    );
    expect(
      LibraryScreen.hasNew(
        item('A', latest: 'https://x/2', last: 'https://x/2'),
      ),
      isFalse,
    );
    expect(LibraryScreen.hasNew(item('A')), isFalse);
  });
}

Map<String, dynamic> item(String title, {String? latest, String? last}) => {
  'title': title,
  'latest_chapter_url': latest,
  'latest_chapter_title': null,
  'last_chapter_url': last,
};
