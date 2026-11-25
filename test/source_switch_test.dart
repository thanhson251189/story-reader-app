import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/sources/registry.dart';
import 'package:story_reader/sources/source_switch.dart';

ChapterRef ch(String url, String title) => ChapterRef(title: title, url: url);

void main() {
  test('đổi nguồn: ưu tiên cùng số chương dù vị trí mục lục lệch', () {
    final mapped = SourceSwitch.mapChapter(
      oldToc: [
        ch('https://a.test/t/1', 'Chương 1'),
        ch('https://a.test/t/2', 'Chương 2'),
      ],
      currentChapterUrl: 'https://a.test/t/2',
      currentChapterTitle: 'Chương 2',
      newToc: [
        ch('https://b.test/x/1', 'Chương 1'),
        ch('https://b.test/x/2', 'Chương 2'),
        ch('https://b.test/x/3', 'Chương 3'),
      ],
    );
    expect(mapped!.url, 'https://b.test/x/2');
  });

  test('đổi nguồn: không có số thì khớp tên chương bỏ dấu', () {
    final mapped = SourceSwitch.mapChapter(
      oldToc: [ch('https://a.test/mo-dau', 'Mở đầu')],
      currentChapterUrl: 'https://a.test/mo-dau',
      currentChapterTitle: 'Mở Đầu',
      newToc: [
        ch('https://b.test/bat-dau', 'Bắt đầu'),
        ch('https://b.test/mo-dau', 'Mở đầu'),
      ],
    );
    expect(mapped!.url, 'https://b.test/mo-dau');
  });

  test('đổi nguồn: cùng vị trí trong mục lục khi không khớp số/tên', () {
    final mapped = SourceSwitch.mapChapter(
      oldToc: [ch('https://a.test/p1', 'Một'), ch('https://a.test/p2', 'Hai')],
      currentChapterUrl: 'https://a.test/p2',
      currentChapterTitle: 'Hai',
      newToc: [
        ch('https://b.test/q1', 'Alpha'),
        ch('https://b.test/q2', 'Beta'),
      ],
    );
    expect(mapped!.url, 'https://b.test/q2');
  });

  test('đổi nguồn: không khớp gì thì mở chương đầu', () {
    final mapped = SourceSwitch.mapChapter(
      oldToc: const [],
      currentChapterUrl: 'https://a.test/zzz',
      currentChapterTitle: '',
      newToc: [ch('https://b.test/q1', 'Alpha')],
    );
    expect(mapped!.url, 'https://b.test/q1');
  });

  test('đổi nguồn: mục lục mới rỗng trả null', () {
    expect(
      SourceSwitch.mapChapter(
        oldToc: const [],
        currentChapterUrl: 'https://a.test/1',
        currentChapterTitle: 'Chương 1',
        newToc: const [],
      ),
      isNull,
    );
  });

  test('mục 18+: khớp domain và subdomain, không khớp domain khác', () {
    const adult = {'truyensacfull.com', 'truyenc.vn'};
    expect(SourceRegistry.isAdultHost('truyensacfull.com', adult), isTrue);
    expect(SourceRegistry.isAdultHost('www.truyensacfull.com', adult), isTrue);
    expect(SourceRegistry.isAdultHost('m.truyenc.vn', adult), isTrue);
    expect(SourceRegistry.isAdultHost('truyendich.us', adult), isFalse);
    expect(SourceRegistry.isAdultHost('', adult), isFalse);
  });

  test(
    'DB: thay nguồn giữ tiến độ, bỏ dòng cũ, giữ dữ liệu nguồn cũ',
    () async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      const fileName = 'test_source_switch.db';
      final path = p.join(await getDatabasesPath(), fileName);
      if (await databaseFactory.databaseExists(path)) {
        await databaseFactory.deleteDatabase(path);
      }
      final db = AppDb(fileName: fileName);
      const oldStory = 'https://a.test/truyen';
      const newStory = 'https://b.test/truyen';
      await db.upsertLibrary(
        storyUrl: oldStory,
        title: 'Truyện cũ',
        lastChapterUrl: '$oldStory/chuong-5',
      );
      await db.saveToc(oldStory, [
        for (var i = 1; i <= 5; i++)
          ChapterRef(title: 'Chương $i', url: '$oldStory/chuong-$i'),
      ]);
      await db.savePosition('$oldStory/chuong-5', 0.7);
      await db.setWordFixes([
        const WordFix('gi ết', 'giết', storyUrl: oldStory),
        const WordFix('abc', 'def'),
      ]);

      final newToc = [
        for (var i = 1; i <= 6; i++)
          ChapterRef(title: 'Chương $i', url: '$newStory/chuong-$i'),
      ];
      await db.switchLibrarySource(
        oldStoryUrl: oldStory,
        newStoryUrl: newStory,
        title: 'Truyện mới',
        chapterUrl: '$newStory/chuong-5',
        toc: newToc,
      );

      final lib = await db.getLibrary();
      expect(lib.map((r) => r['story_url']), [newStory]);
      expect(lib.single['title'], 'Truyện mới');
      expect(lib.single['last_chapter_url'], '$newStory/chuong-5');
      expect(await db.getToc(newStory), hasLength(6));
      expect(await db.getPosition('$newStory/chuong-5'), 0.0);
      expect(await db.getSetting('lastUrl'), '$newStory/chuong-5');
      expect(await db.getSetting('lastTitle'), 'Truyện mới');
      // Dữ liệu nguồn cũ còn để quay lại, không bị xoá oan.
      expect(await db.getToc(oldStory), hasLength(5));
      expect(await db.getPosition('$oldStory/chuong-5'), 0.7);
      // Sửa từ riêng của truyện đi theo nguồn mới; mục chung giữ nguyên.
      final fixes = await db.getWordFixes();
      expect(fixes, hasLength(3));
      expect(
        fixes.any(
          (f) =>
              f.storyUrl != null && f.sameScope(newStory) && f.from == 'gi ết',
        ),
        isTrue,
      );
      expect(fixes.where((f) => f.storyUrl == null), hasLength(1));
      await (await db.database).close();
    },
  );
}
