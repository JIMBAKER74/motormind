import 'package:flutter_test/flutter_test.dart';
import 'package:motormind/features/chat/cards/formatting.dart';

void main() {
  group('money', () {
    test('separates thousands and shows cents by default', () {
      expect(money(1234567.891), r'$1,234,567.89');
      expect(money(0), r'$0.00');
      expect(money(999), r'$999.00');
    });

    test('rounds to whole dollars without cents', () {
      expect(money(27995.5, cents: false), r'$27,996');
      expect(money(1000, cents: false), r'$1,000');
    });

    test('keeps the sign in front of the dollar', () {
      expect(money(-2500.25), r'-$2,500.25');
      expect(money(-2500.25, cents: false), r'-$2,500');
    });

    test('passes a non-number through as text so a card never crashes', () {
      expect(money('n/a'), 'n/a');
      expect(money(null), '');
    });
  });

  group('percent', () {
    test('formats a fraction with two decimals', () {
      expect(percent(0.0699), '6.99%');
      expect(percent(1), '100.00%');
      expect(percent('x'), '');
    });
  });

  group('thousands', () {
    test('rounds and separates', () {
      expect(thousands(45000), '45,000');
      expect(thousands(1234.6), '1,235');
      expect(thousands(12), '12');
      expect(thousands(null), '');
    });
  });

  group('labelFor', () {
    test('reads camelCase and snake_case as a sentence', () {
      expect(labelFor('totalCost'), 'Total cost');
      expect(labelFor('monthly_payment'), 'Monthly payment');
      expect(labelFor('apr'), 'Apr');
    });
  });
}
