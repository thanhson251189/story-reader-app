import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:story_reader/core/models.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/data/backup.dart';

/// Sao lưu/phục hồi dùng batch cho settings/library/toc/positions — test này
/// kiểm dữ liệu sang DB mới đủ chứ không chỉ chạy không lỗi.
void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<AppDb> freshDb(String name) async {
    final path = p.join(await getDatabasesPath(), name);
    if (await databaseFactory.databaseExists(path)) {
      await databaseFactory.deleteDatabase(path);
    }
    return AppDb(fileName: name);
  }

  test('sao lưu rồi phục hồi: cài đặt, thư viện, mục lục, vị trí, sách đủ', () async {
    final src = await freshDb('test_backup_src.db');
    const story = 'https://x.test/truyen';
    await src.upsertLibrary(
      storyUrl: story,
      title: 'Truyện',
      lastChapterUrl: '$story/c1',
    );
    await src.saveToc(story, [
      ChapterRef(title: 'Chương 1', url: '$story/c1'),
      ChapterRef(title: 'Chương 2', url: '$story/c2'),
    ]);
    await src.savePosition('$story/c1', 0.4);
    await src.setSetting('lastTitle', 'Truyện');
    await src.cacheChapter(
      ChapterContent(
        url: 'book:b1:0',
        title: 'Chương 1',
        paragraphs: const ['nội dung sách'],
      ),
    );

    final data = await DataBackup(src).export();
    await (await src.database).close();

    final dst = await freshDb('test_backup_dst.db');
    await DataBackup(dst).import(data);

    expect((await dst.getLibrary()).single['title'], 'Truyện');
    expect(await dst.getToc(story), hasLength(2));
    expect(await dst.getPosition('$story/c1'), 0.4);
    expect(await dst.getSetting('lastTitle'), 'Truyện');
    expect(
      (await dst.getCachedChapter('book:b1:0'))?.paragraphs,
      ['nội dung sách'],
    );

    await (await dst.database).close();
  });
}
