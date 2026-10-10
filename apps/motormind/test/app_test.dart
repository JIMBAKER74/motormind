import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/advisor/advisor_surface.dart';
import 'package:motormind/features/chat/external_tools.dart';
import 'package:motormind/features/disclosures/disclosures_notifier.dart';
import 'package:motormind/features/search/search_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

void main() {
  testWidgets('first launch shows the disclosure gate with every disclosure', (tester) async {
    await tester.pumpWidget(await motormindApp());
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gate-acknowledge')), findsOneWidget);
    for (final d in Disclosures.all) {
      expect(find.byKey(ValueKey('disclosure-${d.key}')), findsOneWidget);
    }
  });

  testWidgets('acknowledging the gate opens home and persists', (tester) async {
    await tester.pumpWidget(await motormindApp());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('gate-acknowledge')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-bubble')), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(DisclosuresAcknowledgedNotifier.ackKey), Disclosures.gateVersion);
  });

  testWidgets('an acknowledged current version skips the gate; an old version does not', (
    tester,
  ) async {
    await tester.pumpWidget(await motormindApp(acknowledgedVersion: Disclosures.gateVersion));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-bubble')), findsOneWidget);

    await tester.pumpWidget(await motormindApp(acknowledgedVersion: Disclosures.gateVersion - 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('gate-acknowledge')), findsOneWidget);
  });

  testWidgets('the surface cycles collapsed → docked → fullscreen → collapsed', (tester) async {
    await tester.pumpWidget(await motormindApp(acknowledgedVersion: Disclosures.gateVersion));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('surface-bubble')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-docked')), findsOneWidget);
    await tester.tap(find.byKey(const Key('surface-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-fullscreen')), findsOneWidget);
    await tester.tap(find.byKey(const Key('surface-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('surface-bubble')), findsOneWidget);
  });

  test('model requests and the person\'s control both move the surface', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final n = container.read(surfaceProvider.notifier);
    n.request(SurfaceState.fullscreen);
    expect(container.read(surfaceProvider), SurfaceState.fullscreen);
    n.request(SurfaceState.collapsed);
    expect(container.read(surfaceProvider), SurfaceState.collapsed);
    n.userSet(SurfaceState.docked);
    expect(container.read(surfaceProvider), SurfaceState.docked);
  });

  test('read_page hands the fake reader\'s listings to the model', () async {
    final now = DateTime(2026, 10, 6);
    final container = ProviderContainer(
      overrides: [
        pageReaderProvider.overrideWithValue(
          ({url}) async => PageExtract(
            url: url ?? 'https://www.echopark.com/used-cars',
            title: 'Fake results',
            text: 'Two cars',
            listings: [
              VehicleListing(
                id: 'f1',
                title: '2021 Honda CR-V EX',
                sourceUrl: 'https://www.echopark.com/used-cars',
                readAt: now,
                price: 27995,
                make: 'Honda',
              ),
            ],
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final out = await container.read(externalToolsProvider).call('read_page', {});
    expect(out['title'], 'Fake results');
    expect(out['text'], 'Two cars');
    final listings = (out['listings'] as List).cast<Map>();
    expect(listings.single['title'], '2021 Honda CR-V EX');
    // The model may only name curated sites; anything else is refused.
    final refused = await container.read(externalToolsProvider).call('read_page', {
      'url': 'https://example.com/',
    });
    expect(refused['error'], isNotNull);
  });
}
