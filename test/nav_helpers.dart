import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens adding devices and connections (More > Add devices). It used to be the Connect tab.
Future<void> openConnectTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('tab-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('more-connect')));
  await tester.pumpAndSettle();
}

/// Opens the list of every device (More > All devices). It used to be the Devices tab.
Future<void> openDevicesTab(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('tab-more')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('more-devices')));
  await tester.pumpAndSettle();
}
