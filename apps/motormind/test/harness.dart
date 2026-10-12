import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/app/app.dart';
import 'package:motormind/app/prefs.dart';
import 'package:motormind/features/advisor/stage_view.dart';
import 'package:motormind/features/disclosures/disclosures_notifier.dart';
import 'package:motormind/features/search/search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The app under test: mock preferences (with the disclosure gate already
/// passed when [acknowledgedVersion] is [Disclosures.gateVersion]), the web
/// pane replaced by a keyed box so no platform webview is needed, every
/// page read answered by [pageReader] (an empty page unless given, since
/// the app reads the site's first page at launch), plus the caller's own
/// [overrides].
Future<Widget> motormindApp({
  int? acknowledgedVersion,
  PageReader? pageReader,
  List<Override> overrides = const [],
}) async {
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
      pageReaderProvider.overrideWithValue(pageReader ?? emptyPageReader),
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

/// A page with nothing on it, for tests that do not care what was read.
Future<PageExtract> emptyPageReader({String? url}) async => PageExtract(
  url: url ?? CuratedSites.defaultSite.home,
  title: 'Empty page',
  text: '',
  listings: const [],
);
