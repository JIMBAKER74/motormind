import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  group('parseTolerantNumber', () {
    test('reads the spellings a model, a person and a page use', () {
      expect(parseTolerantNumber('50k'), 50000);
      expect(parseTolerantNumber('35K'), 35000);
      expect(parseTolerantNumber('25.5k'), 25500);
      expect(parseTolerantNumber(r'$9,500'), 9500);
      expect(parseTolerantNumber('6%'), closeTo(0.06, 1e-12));
      expect(parseTolerantNumber(' 1,200 '), 1200);
      expect(parseTolerantNumber('18 500'), 18500);
      expect(parseTolerantNumber('0.06'), 0.06);
      expect(parseTolerantNumber(r'$1,234.50'), 1234.5);
    });

    test('passes numbers through and refuses everything else', () {
      expect(parseTolerantNumber(18500), 18500.0);
      expect(parseTolerantNumber(0.06), 0.06);
      expect(parseTolerantNumber(null), isNull);
      expect(parseTolerantNumber(''), isNull);
      expect(parseTolerantNumber('soon'), isNull);
      expect(parseTolerantNumber('k'), isNull);
      expect(parseTolerantNumber(true), isNull);
      expect(parseTolerantNumber(['1']), isNull);
    });
  });
}
