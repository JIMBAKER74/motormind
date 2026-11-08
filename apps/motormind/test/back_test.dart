import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/services/app_window.dart';

import 'harness.dart';

void main() {
  testWidgets('Back on the first screen sends the app to the background', (tester) async {
    final calls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(appWindowChannel, (call) async {
      calls.add(call.method);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(appWindowChannel, null),
    );
    await tester.pumpWidget(await motormindApp(acknowledgedVersion: Disclosures.gateVersion));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(calls, ['moveToBackground']);
    expect(find.byKey(const Key('stage')), findsOneWidget);
  });
}
