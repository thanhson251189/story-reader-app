import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';

ChapterContent ch(String url) =>
    ChapterContent(url: url, title: 'Chương', paragraphs: const ['Nội dung']);

void main() {
  const fileName = 'test_story_cache.db';

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), fileName);
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
  });

  test(
    'đếm và xoá cache theo đúng một truyện, không đụng truyện khác',
    () async {
      final db = AppDb(fileName: fileName);
      const a = 'https://a.test/truyen';
      const b = 'https://b.test/truyen';
      await db.saveToc(a, [
        for (var i = 1; i <= 3; i++)
          ChapterRef(title: 'Chương $i', url: '$a/chuong-$i'),
      ]);
      await db.cacheChapter(ch('$a/chuong-1'));
      await db.cacheChapter(ch('$a/chuong-2'));
      await db.cacheChapter(ch('$a/chuong-3'));
      await db.pinChapter('$a/chuong-2');
      await db.cacheChapter(ch('$b/chuong-1'));
      await db.cacheChapter(ch('book:abc:0'));

      expect(await db.cachedChapterCountForStory(a), 3);
      expect(await db.cachedChapterCountForStory(b), 1);

      final deleted = await db.clearCachedChaptersForStory(a);
      expect(deleted, 3);
      expect(await db.cachedChapterCountForStory(a), 0);
      expect(await db.cachedChapterCountForStory(b), 1);
      expect(await db.getCachedChapter('book:abc:0'), isNotNull);
      expect(await db.getCachedChapter('$b/chuong-1'), isNotNull);
      await (await db.database).close();
    },
  );
}
