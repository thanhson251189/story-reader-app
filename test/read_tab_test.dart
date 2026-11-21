import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/core/providers.dart';
import 'package:story_reader/data/app_db.dart';
import 'package:story_reader/home/read_tab.dart';

class FakeAppDb extends AppDb {
  final settings = <String, String>{};

  @override
  Future<String?> getSetting(String key) async => settings[key];

  @override
  Future<void> setSetting(String key, String value) async {
    settings[key] = value;
  }

  @override
  Future<List<Map<String, dynamic>>> getLibrary() async => const [];
}

void main() {
  testWidgets('Quay lại tab Đọc phải nạp lại "Đọc tiếp" từ dữ liệu mới', (
    tester,
  ) async {
    final db = FakeAppDb();
    db.settings['lastUrl'] = 'https://x.test/truyen-cu/chuong-1';

    Future<void> pump(bool active) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [appDbProvider.overrideWithValue(db)],
          child: MaterialApp(home: ReadTab(active: active)),
        ),
      );
      await tester.pumpAndSettle();
    }

    // Mở app: thẻ "Đọc tiếp" hiện truyện lúc mở app.
    await pump(true);
    expect(find.text('https://x.test/truyen-cu/chuong-1'), findsOneWidget);

    // Đọc truyện khác qua Thư viện (lastUrl trong DB đổi) rồi quay lại tab Đọc.
    db.settings['lastUrl'] = 'https://x.test/truyen-moi/chuong-9';
    await pump(false);
    await pump(true);

    expect(find.text('https://x.test/truyen-cu/chuong-1'), findsNothing);
    expect(find.text('https://x.test/truyen-moi/chuong-9'), findsOneWidget);
  });
}
