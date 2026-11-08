import 'package:advisor_core/advisor_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/browser/browser_service.dart';
import 'package:motormind/features/chat/chat_strings.dart';
import 'package:motormind/features/listings/listing_cache.dart';
import 'package:motormind/features/search/search_service.dart';

import 'harness.dart';

const _site = 'https://www.echopark.com/used-cars';

VehicleListing _car(String id, String title, String make, double price) => VehicleListing(
  id: id,
  title: title,
  sourceUrl: _site,
  readAt: DateTime.now().subtract(const Duration(hours: 3)),
  price: price,
  make: make,
  detailUrl: 'https://www.echopark.com/car/$id',
);

Future<PageExtract> _unreachable({String? url}) async =>
    throw PageUnreachableException(url ?? _site);

/// The app with the site not answering, and these cars remembered.
Future<ProviderContainer> _launch(
  WidgetTester tester, {
  required List<VehicleListing> remembered,
  PageReader reader = _unreachable,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
  final cache = MemoryListingCache();
  await cache.save('echopark', remembered);
  await tester.pumpWidget(
    await motormindApp(
      acknowledgedVersion: Disclosures.gateVersion,
      listingCache: cache,
      pageReader: reader,
      overrides: [searchDebounceProvider.overrideWithValue(Duration.zero)],
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byKey(const Key('home-models'))));
}

final _cars = [
  _car('A', '2021 Kia Sorento SX', 'Kia', 24000),
  _car('B', '2022 Honda CR-V EX', 'Honda', 29000),
];

void main() {
  testWidgets('with the site down, remembered cars still show and say why', (tester) async {
    final c = await _launch(tester, remembered: _cars);
    expect(find.textContaining('Kia Sorento'), findsOneWidget);
    final s = c.read(searchProvider);
    expect(s.fromMemory, isTrue);
    expect(s.note, ChatStrings.siteUnreachable('EchoPark'));
    expect(s.applying, isFalse);
  });

  testWidgets('with the site down, a filter still narrows the remembered cars', (tester) async {
    final c = await _launch(tester, remembered: _cars);
    c.read(searchProvider.notifier).update({'make': 'Honda'});
    await tester.pumpAndSettle();
    expect(find.textContaining('Honda CR-V'), findsOneWidget);
    expect(find.textContaining('Kia Sorento'), findsNothing);
    expect(c.read(searchProvider).lastCount, 1);
    expect(c.read(searchProvider).fromMemory, isTrue);
  });

  testWidgets('with nothing remembered, it says so rather than showing an empty result', (
    tester,
  ) async {
    final c = await _launch(tester, remembered: const []);
    final s = c.read(searchProvider);
    expect(s.note, ChatStrings.siteUnreachableNothingKept('EchoPark'));
    expect(s.fromMemory, isFalse);
  });

  testWidgets('when the site answers again, the cards are fresh and the note goes', (tester) async {
    var online = false;
    Future<PageExtract> reader({String? url}) async {
      if (!online) throw PageUnreachableException(url ?? _site);
      return PageExtract(
        url: url ?? _site,
        title: 'Results',
        text: '',
        listings: [_car('C', '2023 Toyota RAV4 LE', 'Toyota', 31000)],
      );
    }

    final c = await _launch(tester, remembered: _cars, reader: reader);
    expect(c.read(searchProvider).fromMemory, isTrue);
    online = true;
    await c.read(searchProvider.notifier).apply();
    await tester.pumpAndSettle();
    final s = c.read(searchProvider);
    expect(s.fromMemory, isFalse);
    expect(s.note, isNull);
    expect(find.textContaining('Toyota RAV4'), findsOneWidget);
  });
}
