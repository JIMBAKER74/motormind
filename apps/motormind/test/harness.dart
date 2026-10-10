import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/app/app.dart';
import 'package:motormind/app/prefs.dart';
import 'package:motormind/features/advisor/stage_view.dart';
import 'package:motormind/features/disclosures/disclosures_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app under test: mock preferences (with the disclosure gate already
/// passed when [acknowledgedVersion] is [Disclosures.gateVersion]), the web
/// pane replaced by a keyed box so no platform webview is needed, plus the
/// caller's own [overrides].
Future<Widget> motormindApp({int? acknowledgedVersion, List<Override> overrides = const []}) async {
  SharedPreferences.setMockInitialValues({
    DisclosuresAcknowledgedNotifier.ackKey: ?acknowledgedVersion,
  });
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      webPaneBuilderProvider.overrideWithValue(
        () => const SizedBox.expand(key: Key('browser-pane')),
      ),
      ...overrides,
    ],
    child: const MotormindApp(),
  );
}

/// The app's container, reached through the chat panel (its start button
/// before a conversation, its input after), which is on screen whenever the
/// surface is open.
ProviderContainer containerOf(WidgetTester tester) {
  final start = find.byKey(const Key('chat-start'));
  final anchor = start.evaluate().isNotEmpty ? start : find.byKey(const Key('chat-input'));
  return ProviderScope.containerOf(tester.element(anchor));
}
