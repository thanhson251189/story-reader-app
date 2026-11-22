import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';

/// Test danh sách từ/cụm từ sửa lỗi người dùng dạy. DB thật qua FFI
/// (SQLite chạy trên máy phát triển, không vào app production), dùng file
/// DB riêng để không đụng các file test khác chạy song song.
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), 'test_word_fixes.db');
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  ChapterContent chapter() => ChapterContent(
    url: 'https://x/chuong-1',
    title: 'Thi th ể gi ết người',
    paragraphs: ['Hắn gi ết người rồi.', 'Bình thường.', 'Thi th ể nằm đó.'],
    nextUrl: 'https://x/chuong-2',
  );

  test('Chưa dạy cụm từ nào: danh sách rỗng, fixWords trả nguyên văn', () async {
    final db = AppDb(fileName: 'test_word_fixes.db');
    expect(await db.getWordFixes(), isEmpty);
    final c = chapter();
    final fixed = await db.fixWords(c);
    expect(fixed.url, c.url);
    expect(fixed.title, c.title);
    expect(fixed.paragraphs, c.paragraphs);
    expect(fixed.nextUrl, c.nextUrl);
  });

  test('Chuẩn hóa bỏ ký tự rác chèn giữa chữ ("s.á.t" → "sát")', () async {
    final db = AppDb(fileName: 'test_word_fixes.db');
    final fixed = await db.fixWords(
      ChapterContent(
        url: 'u',
        title: 'C\u200Bhương 1',
        paragraphs: [
          'Hắn s.á.t người rồi.',
          'Tôi...anh không nói dối, kết thúc.',
          'b\u00ADát và 1.5 triệu.',
        ],
      ),
    );
    // Chấm giữa chữ bị bỏ; ký tự vô hình (zero-width, soft hyphen) bị bỏ.
    expect(fixed.title, 'Chương 1');
    expect(fixed.paragraphs[0], 'Hắn sát người rồi.');
    expect(fixed.paragraphs[2], 'bát và 1.5 triệu.');
    // Chấm lửng run nhiều chấm + chấm câu (sau nó là khoảng trắng/hết câu)
    // giữ nguyên.
    expect(fixed.paragraphs[1], 'Tôi...anh không nói dối, kết thúc.');
  });

  test('set/get giữ thứ tự, fixWords áp tiêu đề + từng đoạn, giữ URL', () async {
    final db = AppDb(fileName: 'test_word_fixes.db');
    // Khớp nguyên văn nên pattern phải đúng cả hoa thường của dữ liệu mẫu.
    await db.setWordFixes([('gi ết', 'giết'), ('Thi th ể', 'Thi thể')]);
    expect(await db.getWordFixes(), [
      ('gi ết', 'giết'),
      ('Thi th ể', 'Thi thể'),
    ]);

    final fixed = await db.fixWords(chapter());
    expect(fixed.title, 'Thi thể giết người');
    expect(fixed.paragraphs, [
      'Hắn giết người rồi.',
      'Bình thường.',
      'Thi thể nằm đó.',
    ]);
    expect(fixed.url, 'https://x/chuong-1');
    expect(fixed.nextUrl, 'https://x/chuong-2');
  });

  test('Dữ liệu hỏng trong settings bị bỏ qua thay vì crash', () async {
    final db = AppDb(fileName: 'test_word_fixes.db');
    await db.setSetting(AppDb.wordFixesKey, '[["a","b"],["x"],["ok","v"],4]');
    expect(await db.getWordFixes(), [('a', 'b'), ('ok', 'v')]);
    // Cụm từ sai rỗng thì thay tất cả — vô nghĩa, phải lọc bỏ.
    await db.setSetting(AppDb.wordFixesKey, '[["","b"],["ok","v"]]');
    expect(await db.getWordFixes(), [('ok', 'v')]);
    await db.setSetting(AppDb.wordFixesKey, 'not json{');
    expect(await db.getWordFixes(), isEmpty);
  });

  test('Khớp nguyên văn, phân biệt hoa thường', () async {
    final db = AppDb(fileName: 'test_word_fixes.db');
    await db.setWordFixes([('Gi ết', 'Giết')]);
    final fixed = await db.fixWords(
      ChapterContent(
        url: 'u',
        title: 't',
        paragraphs: ['Gi ết thì đổi, gi ết không đổi.'],
      ),
    );
    expect(fixed.paragraphs.first, 'Giết thì đổi, gi ết không đổi.');
  });
}
