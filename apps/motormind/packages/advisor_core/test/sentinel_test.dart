import 'package:advisor_core/advisor_core.dart';
import 'package:test/test.dart';

void main() {
  test('orKeep tells an omitted argument from an explicit null', () {
    expect(orKeep<String>(unset, 'current'), 'current');
    expect(orKeep<String>(null, 'current'), isNull);
    expect(orKeep<String>('new', 'current'), 'new');
    expect(orKeep<int>(unset, null), isNull);
  });

  test('copyWith-style methods share the sentinel', () {
    const q = SearchQuery(make: 'Toyota', maxPrice: 20000);
    expect(q.copyWith().make, 'Toyota');
    expect(q.copyWith(make: null).make, isNull);
    expect(q.copyWith(make: null).maxPrice, 20000);
    const r = ReadingRecipe(siteId: 'x', version: 1, card: 'div', fields: {}, note: 'kept');
    expect(r.withStatus(RecipeStatus.broken).note, 'kept');
    expect(r.withStatus(RecipeStatus.broken, note: null).note, isNull);
  });
}
