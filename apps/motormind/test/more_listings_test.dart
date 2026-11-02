import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/recipes/recipe_store.dart';
import 'package:motormind/features/search/search_service.dart';

import 'harness.dart';

void main() {
  testWidgets('More from EchoPark reads page 2 and adds its cars to the card', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final urls = <String?>[];
    final now = DateTime.now();
    VehicleListing car(String title, double price, String url) =>
        VehicleListing(id: title, title: title, sourceUrl: url, readAt: now, price: price);
    Future<PageExtract> reader({String? url}) async {
      urls.add(url);
      final u = url ?? CuratedSites.defaultSite.home;
      final page2 = u.contains('page=2');
      return PageExtract(
        url: u,
        title: 'Results',
        text: '',
        listings: page2
            ? [car('2019 Mazda CX-5 Touring', 18000, u)]
            : [car('2021 Kia Sorento SX', 19422, u), car('2024 Nissan LEAF S', 15722, u)],
      );
    }

    await tester.pumpWidget(
      await motormindApp(acknowledgedVersion: Disclosures.gateVersion, pageReader: reader),
    );
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('stage'))));
    // The site says it has more than the card holds (the real read records
    // this from the page's own total).
    container
        .read(lastReadsProvider.notifier)
        .record(
          'echopark',
          3,
          const SelfCheck(ok: true, cardsFound: 2, withPrice: 2, withImage: 0, pageTotal: 40),
        );
    await tester.pumpAndSettle();
    final more = find.byKey(const Key('more-listings'));
    expect(more, findsOneWidget);
    expect(find.text('More from EchoPark (2 of 40)'), findsOneWidget);
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(urls.last, endsWith('page=2'));
    expect(container.read(searchProvider).page, 2);
    expect(find.text('2019 Mazda CX-5 Touring'), findsOneWidget);
    expect(find.text('2021 Kia Sorento SX'), findsOneWidget);
  });
}
