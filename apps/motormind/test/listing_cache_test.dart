import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/listings/listing_cache.dart';
import 'package:motormind/features/search/search_service.dart';

import 'harness.dart';

final _then = DateTime(2026, 10, 20);

VehicleListing _car(String vin, {String? image, double price = 20000}) => VehicleListing(
  id: vin,
  title: '2021 Kia Sorento SX',
  sourceUrl: 'https://www.echopark.com/used-cars',
  readAt: _then,
  price: price,
  mileage: 77000,
  imageUrl: image,
  detailUrl: 'https://www.echopark.com/car/$vin',
);

void main() {
  group('merge rules', () {
    test('a fresh listing without a photo keeps the one it was remembered with', () {
      final out = ListingCache.withRememberedPhotos(
        [_car('A'), _car('B', image: 'https://img/b-new.jpg')],
        [_car('A', image: 'https://img/a.jpg'), _car('B', image: 'https://img/b-old.jpg')],
      );
      expect(out.map((l) => l.imageUrl), ['https://img/a.jpg', 'https://img/b-new.jpg']);
    });

    test('a price drop is the same car (keyed by its detail page)', () {
      final merged = ListingCache.merge(
        [_car('A', price: 18000)],
        [_car('A', image: 'https://img/a.jpg'), _car('C')],
      );
      expect(merged.map((l) => (l.detailUrl!.split('/').last, l.price)), [
        ('A', 18000.0),
        ('C', 20000.0),
      ]);
      expect(merged.first.imageUrl, 'https://img/a.jpg');
    });

    test('at most maxPerSite are kept, newest first', () {
      final many = [for (var i = 0; i < ListingCache.maxPerSite + 5; i++) _car('V$i')];
      expect(ListingCache.merge(many, const []), hasLength(ListingCache.maxPerSite));
    });
  });

  testWidgets(
    'a launch shows the last launch\'s cards, photos included, when the read finds none',
    (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);
      final cache = MemoryListingCache();
      await cache.save('echopark', [_car('A', image: 'https://img/a.jpg')]);
      await tester.pumpWidget(
        await motormindApp(acknowledgedVersion: Disclosures.gateVersion, listingCache: cache),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('photo-https://img/a.jpg')), findsOneWidget);
      expect(find.textContaining('2021 Kia Sorento SX'), findsOneWidget);
      // The fresh read found nothing new; the remembered car is still one of
    // this session's listings, so it still counts.
      // The panel is collapsed, so the container is reached through the stage.
      final container = ProviderScope.containerOf(tester.element(find.byKey(const Key('stage'))));
      expect(container.read(searchProvider).lastCount, 1);
    },
  );
}
