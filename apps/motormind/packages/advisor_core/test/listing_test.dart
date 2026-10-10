import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

import 'test_support.dart';

void main() {
  group('VehicleListing JSON', () {
    test('round-trips every field through toJson and fromJson', () {
      final full = VehicleListing(
        id: 'v1',
        title: '2021 Honda Civic Si',
        sourceUrl: 'https://www.cars.com/shopping/results/',
        readAt: testReadAt,
        price: 24998,
        mileage: 34210,
        year: 2021,
        make: 'Honda',
        model: 'Civic Si',
        bodyStyle: 'sedan',
        imageUrl: 'https://img.example.com/abc111.jpg',
        detailUrl: 'https://www.cars.com/vehicledetail/abc111/',
      );
      final back = VehicleListing.fromJson(full.toJson());
      expect(back.toJson(), full.toJson());
      expect(back.readAt, testReadAt);
      expect(back.dedupeKey, full.dedupeKey);
    });

    test('tolerates missing optionals and a numeric string', () {
      final sparse = VehicleListing.fromJson({
        'id': 'v2',
        'title': '2019 Ford Mustang GT',
        'sourceUrl': 'u',
        'readAt': testReadAt.toIso8601String(),
        'price': '27,995',
      });
      expect(sparse.price, 27995);
      expect(sparse.mileage, isNull);
      expect(sparse.year, isNull);
      expect(sparse.make, isNull);
      expect(sparse.imageUrl, isNull);
      expect(sparse.toJson()['detailUrl'], isNull);
    });
  });
}
