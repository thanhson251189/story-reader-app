import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/home/mini_player.dart';

void main() {
  testWidgets('Mini-player gọn ở cỡ chữ 1.6, có nút và chạm mở', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2412);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    var toggled = 0;
    var closed = 0;
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.6)),
            child: Scaffold(
              bottomNavigationBar: MiniPlayerBar(
                title: 'Kiếm Đạo Đệ Nhất',
                subtitle: 'Chương 741: Đạo cuối cùng',
                playing: true,
                loading: false,
                onToggle: () => toggled++,
                onClose: () => closed++,
                onOpen: () => opened++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Kiếm Đạo Đệ Nhất'), findsOneWidget);
    expect(find.text('Chương 741: Đạo cuối cùng'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mini-player-toggle')));
    await tester.tap(find.byKey(const ValueKey('mini-player-close')));
    await tester.tap(find.text('Chương 741: Đạo cuối cùng'));
    expect(toggled, 1);
    expect(closed, 1);
    expect(opened, 1);
  });

  testWidgets('Đang tải thì không bấm được nút phát', (tester) async {
    var toggled = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          bottomNavigationBar: MiniPlayerBar(
            title: 'Truyện',
            subtitle: 'Đang tải chương…',
            playing: false,
            loading: true,
            onToggle: () => toggled++,
            onClose: () {},
            onOpen: () {},
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mini-player-toggle')));
    expect(toggled, 0);
  });
}
