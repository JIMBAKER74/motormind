import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

void main() {
  group('enumByName', () {
    test('matches a name regardless of case and surrounding whitespace', () {
      expect(enumByName(CreditBand.values, 'good'), CreditBand.good);
      expect(enumByName(CreditBand.values, ' Good '), CreditBand.good);
      expect(enumByName(FuelType.values, 'ELECTRIC'), FuelType.electric);
    });

    test('is null for null, an unknown name and a value that is not a name', () {
      expect(enumByName(CreditBand.values, null), isNull);
      expect(enumByName(CreditBand.values, 'platinum'), isNull);
      expect(enumByName(CreditBand.values, 42), isNull);
      expect(enumByName(CreditBand.values, {'name': 'good'}), isNull);
    });
  });

  group('requireEnumByName', () {
    test('returns the member for a known name', () {
      expect(requireEnumByName(VehicleClass.values, ' SUV', 'vehicle_class'), VehicleClass.suv);
    });

    test('refuses null and unknown names with the argument name and the choices', () {
      expect(
        () => requireEnumByName(VehicleClass.values, 'boat', 'vehicle_class'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            'vehicle_class must be one of car, suv, pickup, van',
          ),
        ),
      );
      expect(
        () => requireEnumByName(VehicleClass.values, null, 'vehicle_class'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('vehicle_class is required'), contains('car, suv, pickup, van')),
          ),
        ),
      );
    });
  });
}
