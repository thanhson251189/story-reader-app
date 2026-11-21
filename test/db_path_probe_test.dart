import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  test('probe db path', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = p.join(await getDatabasesPath(), 'test_word_fix_screen.db');
    // ignore: avoid_print
    print('DB_PATH=$path exists=${await databaseFactory.databaseExists(path)}');
  });
}
