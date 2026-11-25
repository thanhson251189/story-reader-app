import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:story_reader/home_screen.dart';

void main() {
  testWidgets('Thanh tab gọn: chữ hệ thống 1.6 không tràn, vẫn đủ nhãn', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2412);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: Scaffold(
              bottomNavigationBar: HomeScreen.navBar(
                index: 2,
                onSelect: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Thư viện'), findsOneWidget);
    expect(find.text('Tìm kiếm'), findsOneWidget);
    expect(find.text('Khám phá'), findsOneWidget);
    expect(find.text('Cài đặt'), findsOneWidget);
  });
}
