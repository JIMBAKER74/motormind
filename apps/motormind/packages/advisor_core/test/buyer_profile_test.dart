import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';
import 'package:vehicle_finance/vehicle_finance.dart';

// PresentRequest and ComponentRegistry have their own file,
// present_request_test.dart; this one covers the profile's labels and JSON.
void main() {
  test('applies an update_profile call without inventing labels', () {
    const p = BuyerProfile();
    final updated = p.applyUpdate({
      'items': [
        {'label': 'seats 7', 'kind': 'need'},
        {'label': 'heated seats', 'kind': 'unlabeled'},
      ],
      'payment_ceiling': 450,
      'credit_score': 690,
      'trade_payoff': '8,000',
      'shopping_mode': 'practical',
    });
    expect(updated.needs.single.label, 'seats 7');
    expect(updated.unlabeled.single.label, 'heated seats');
    expect(updated.paymentCeiling, 450);
    expect(updated.creditBand, CreditBand.good);
    expect(updated.tradePayoff, 8000);
    expect(updated.mode, ShoppingMode.practical);
    expect(updated.toPromptSummary(), contains('mentioned (unlabeled): heated seats'));
  });

  test('relabeling replaces the item, matched without regard to case', () {
    final p = const BuyerProfile()
        .applyUpdate({
          'items': [
            {'label': 'Heated Seats', 'kind': 'unlabeled'},
          ],
        })
        .applyUpdate({
          'items': [
            {'label': 'heated seats', 'kind': 'need'},
          ],
        });
    expect(p.items, hasLength(1));
    expect(p.needs.single.kind, ItemKind.need);
    expect(p.needs.single.label, 'heated seats');
  });

  test('empty profile summarizes as nothing known', () {
    expect(const BuyerProfile().toPromptSummary(), 'nothing known yet');
  });

  test('a credit_score overrides a credit_band given in the same call', () {
    final p = const BuyerProfile().applyUpdate({'credit_band': 'poor', 'credit_score': 790});
    expect(p.creditBand, CreditBand.excellent);
    final q = p.applyUpdate({'credit_band': 'fair'});
    expect(q.creditBand, CreditBand.fair, reason: 'a band alone still updates');
  });

  test('an unknown credit band or mode keeps the previous value instead of throwing', () {
    const p = BuyerProfile(creditBand: CreditBand.good, mode: ShoppingMode.browsing);
    final q = p.applyUpdate({'credit_band': 'platinum', 'shopping_mode': 'serious'});
    expect(q.creditBand, CreditBand.good);
    expect(q.mode, ShoppingMode.browsing);
    expect(p.applyUpdate({'credit_band': ' Good '}).creditBand, CreditBand.good);
  });

  test('numbers arrive as the model writes them', () {
    final p = const BuyerProfile().applyUpdate({
      'payment_ceiling': r'$450',
      'down_payment': '2,000',
      'monthly_debt_payments': 300,
      'credit_score': '690',
    });
    expect(p.paymentCeiling, 450);
    expect(p.downPayment, 2000);
    expect(p.monthlyDebtPayments, 300);
    expect(p.creditBand, CreditBand.good);
  });

  test('the prompt summary puts a dollar sign and thousands separators on every amount', () {
    const p = BuyerProfile(
      paymentCeiling: 450,
      downPayment: 2000,
      monthlyGrossIncome: 5200,
      monthlyDebtPayments: 300,
      tradeValue: 6200,
      tradePayoff: 8000,
    );
    expect(
      p.toPromptSummary(),
      'payment ceiling: \$450/mo; down payment: \$2,000; gross income: \$5,200/mo; '
      'debt payments: \$300/mo; trade-in value: \$6,200, payoff: \$8,000',
    );
    expect(
      const BuyerProfile(tradePayoff: 8000).toPromptSummary(),
      'trade-in value: unknown, payoff: \$8,000',
    );
  });

  test('fromJson tolerates unknown names, odd items and an unknown key', () {
    final p = BuyerProfile.fromJson({
      'items': [
        {'label': 'third row', 'kind': 'essential'},
        'not an item',
      ],
      'creditBand': 'platinum',
      'mode': 'serious',
      'paymentCeiling': '450',
      'preferNew': true,
    });
    expect(p.items.single.label, 'third row');
    expect(p.items.single.kind, ItemKind.unlabeled);
    expect(p.creditBand, isNull);
    expect(p.mode, isNull);
    expect(p.paymentCeiling, 450);
  });

  test('toJson round-trips every field', () {
    final p = const BuyerProfile().applyUpdate({
      'items': [
        {'label': 'seats 7', 'kind': 'need'},
      ],
      'payment_ceiling': 450,
      'down_payment': 1000,
      'credit_band': 'fair',
      'monthly_gross_income': 5200,
      'monthly_debt_payments': 300,
      'trade_value': 6200,
      'trade_payoff': 8000,
      'shopping_mode': 'buying',
    });
    final back = BuyerProfile.fromJson(p.toJson());
    expect(back.toJson(), p.toJson());
    expect(back.needs.single.label, 'seats 7');
    expect(back.mode, ShoppingMode.buying);
  });
}
