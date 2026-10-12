// Prints the structure of a captured results page: the repeated elements
// that look like listing cards, what sits inside them, how images and links
// are carried, and where a result count may be. This is the payload a recipe
// repair works from (ADR 0007, design notes DD-Q16): element names, classes,
// test ids and attribute names, never the page's text, so it can go to a
// person, to the on-device model, or to a hosted help service without
// carrying anything about the person or the inventory.
//
//   dart run tool/recipe_structure.dart <capture.html>
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

/// Fewest look-alike elements that count as a card family; a results page
/// shows more than this, a menu rarely does.
const int minFamily = 8;

/// How many card families and inner names to print.
const int topFamilies = 4;
const int topInner = 24;

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/recipe_structure.dart <capture.html>');
    exit(64);
  }
  final doc = html.parse(File(args[0]).readAsStringSync());
  final body = doc.body ?? doc.documentElement!;

  // 1. Card families: a (tag, class or test id) shared by many elements that
  //    each hold an image and a number (a price or a mileage).
  final families = <String, List<Element>>{};
  for (final e in body.querySelectorAll('*')) {
    if (!_looksLikeCard(e)) continue;
    for (final key in _keysOf(e)) {
      families.putIfAbsent(key, () => []).add(e);
    }
  }
  final ranked = families.entries.where((f) => f.value.length >= minFamily).toList()
    ..sort((a, b) => _familyScore(b).compareTo(_familyScore(a)));
  stdout.writeln('page: ${body.querySelectorAll('*').length} elements');
  stdout.writeln('card families (tag.class or tag[data-testid]: count, outermost first):');
  for (final f in ranked.take(topFamilies)) {
    final cards = f.value;
    stdout.writeln(
      '  ${f.key}: ${cards.length} cards, '
      'depth ${_depth(cards.first)}, ~${_avgDescendants(cards)} elements each',
    );
    _describeInner(cards);
  }
  if (ranked.isEmpty) stdout.writeln('  none: no repeated element holds an image and a number');

  // 2. Where a result count may sit: elements whose name says so.
  stdout.writeln('count candidates (name: text shape, times seen):');
  final shapes = <String, int>{};
  for (final e in body.querySelectorAll('*')) {
    final name = _keysOf(e).join(' ');
    if (!RegExp(r'count|total|results', caseSensitive: false).hasMatch(name)) continue;
    final shape = e.text.trim().replaceAll(RegExp(r'\d'), '#').replaceAll(RegExp(r'\s+'), ' ');
    if (shape.isNotEmpty && shape.length < 60 && shape.contains('#')) {
      final line = '$name: "$shape"';
      shapes[line] = (shapes[line] ?? 0) + 1;
    }
  }
  // Once per card is a per-card figure, not the page's total.
  for (final s in shapes.entries) {
    stdout.writeln('  ${s.key}${s.value > 1 ? ' ×${s.value}' : ''}');
  }
}

bool _looksLikeCard(Element e) {
  if (e.querySelector('img') == null) return false;
  if (!RegExp(r'\d').hasMatch(e.text)) return false;
  final n = e.querySelectorAll('*').length;
  return n >= 5 && n <= 400;
}

Iterable<String> _keysOf(Element e) sync* {
  for (final c in e.classes) {
    yield '${e.localName}.$c';
  }
  final id = e.attributes['data-testid'];
  if (id != null) yield '${e.localName}[data-testid=$id]';
}

/// Many cards, each small, and no card nested in another of the family.
int _familyScore(MapEntry<String, List<Element>> f) {
  final cards = f.value;
  final nested = cards.where(
    (c) => cards.any((o) => o != c && o.querySelectorAll('*').contains(c)),
  );
  return cards.length * 100 - _avgDescendants(cards) - nested.length * 1000;
}

int _depth(Element e) {
  var d = 0;
  for (Element? p = e.parent; p != null; p = p.parent) {
    d++;
  }
  return d;
}

int _avgDescendants(List<Element> cards) =>
    cards.map((c) => c.querySelectorAll('*').length).reduce((a, b) => a + b) ~/ cards.length;

/// Names inside the cards that most cards share, with what they hold.
void _describeInner(List<Element> cards) {
  final presence = <String, int>{};
  final kinds = <String, Set<String>>{};
  for (final card in cards) {
    final seen = <String>{};
    for (final e in card.querySelectorAll('*')) {
      for (final key in _keysOf(e)) {
        if (!seen.add(key)) continue;
        presence[key] = (presence[key] ?? 0) + 1;
        kinds.putIfAbsent(key, () => {}).addAll(_kindsOf(e));
      }
    }
  }
  final common = presence.entries.where((p) => p.value >= cards.length * 0.8).toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final p in common.take(topInner)) {
    stdout.writeln('    ${p.key} (${p.value}/${cards.length}): ${kinds[p.key]!.join(', ')}');
  }
  final imgs = cards.expand((c) => c.querySelectorAll('img'));
  final attrs = <String, int>{};
  for (final i in imgs) {
    for (final a in i.attributes.keys) {
      if (RegExp(r'src|srcset|data-', caseSensitive: false).hasMatch('$a')) {
        attrs['$a'] = (attrs['$a'] ?? 0) + 1;
      }
    }
  }
  stdout.writeln('    img attributes: $attrs');
  final hrefs = cards
      .expand((c) => c.querySelectorAll('a[href]'))
      .map((a) => a.attributes['href']!)
      .map((h) => RegExp(r'^(https?://[^/]+)?(/[^/?#]*)').firstMatch(h)?.group(2) ?? h)
      .toSet();
  stdout.writeln('    link path prefixes: ${hrefs.take(6).toList()}');
  final heads = cards
      .expand((c) => c.querySelectorAll('h1,h2,h3,h4'))
      .map((h) => h.localName)
      .toSet();
  stdout.writeln('    headings: $heads');
}

/// What an element holds, as shapes: a price, a mileage, digits, words.
Iterable<String> _kindsOf(Element e) sync* {
  final t = e.text.trim();
  if (t.isEmpty) return;
  if (RegExp(r'\$\s?[\d,]{4,}').hasMatch(t)) yield 'price';
  if (RegExp(r'[\d,]+\s*(mi|miles|k mi)', caseSensitive: false).hasMatch(t)) yield 'mileage';
  if (RegExp(r'^(19|20)\d\d\s+\w').hasMatch(t)) yield 'year-first title';
  if (!RegExp(r'\d').hasMatch(t) && t.length < 40) yield 'words';
}
