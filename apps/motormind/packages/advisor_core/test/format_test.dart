import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  test('groupThousands separates every three digits and rounds a fraction', () {
    expect(groupThousands(500), '500');
    expect(groupThousands(9500), '9,500');
    expect(groupThousands(1234567), '1,234,567');
    expect(groupThousands(2499.6), '2,500');
    expect(groupThousands(0), '0');
  });

  test('wholeDollars signs and groups an amount and names a missing one', () {
    expect(wholeDollars(2000), r'$2,000');
    expect(wholeDollars(450), r'$450');
    expect(wholeDollars(483.32), r'$483');
    expect(wholeDollars(null), 'unknown');
  });
}
