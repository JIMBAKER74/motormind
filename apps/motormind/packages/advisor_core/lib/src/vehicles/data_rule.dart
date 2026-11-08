import 'dart:convert';

import 'package:html/dom.dart' show Document;

import 'listing.dart';
import 'listing_parse.dart';

/// Where a results page keeps its inventory as data, and how to read it.
///
/// Many listing sites render from a JSON block shipped inside the page (for
/// EchoPark, `script#__JSS_STATE__`): every car on the page with its price,
/// miles, VIN and photo addresses, already downloaded, whether or not the
/// person has scrolled to it. Reading that block gives every card its photo
/// without the app scrolling the page or making a request of its own, and it
/// survives a change of markup better than CSS selectors do. Like the rest of
/// a recipe it is data, not code: a selector, dotted paths and key names.
///
/// Paths are dotted keys; a numeric segment indexes a list (`images.0`). A
/// key may contain a hyphen (`flux-store`) but not a dot.
class DataRule {
  /// Creates a rule; see the fields.
  const DataRule({
    required this.script,
    required this.items,
    required this.fields,
    this.total,
    this.link,
  });

  /// CSS selector for the `<script>` element holding the JSON.
  final String script;

  /// Dotted path from the JSON root to the list of vehicles.
  final String items;

  /// Dotted path from the JSON root to the site's own result count, for the
  /// self-check; null when the data has none.
  final String? total;

  /// Listing field → dotted path inside one vehicle. Known names: year,
  /// make, model, trim, title, price, mileage, image, id. A title is built
  /// from year, make, model and trim when the data has none.
  final Map<String, String> fields;

  /// A detail-page path with `{key}` placeholders filled from the vehicle
  /// (`/car/{vin}`), resolved against the page's address.
  final String? link;

  /// Restores a rule from its JSON form; throws a [FormatException] naming
  /// the field when one is missing or of the wrong type.
  factory DataRule.fromJson(Map<String, Object?> json) {
    String req(String k) => switch (json[k]) {
      final String s when s.isNotEmpty => s,
      _ => throw FormatException('recipe.data: "$k" is required and must be a string'),
    };
    final rawFields = json['fields'];
    if (rawFields is! Map || rawFields.values.any((v) => v is! String)) {
      throw const FormatException('recipe.data: "fields" must map names to path strings');
    }
    return DataRule(
      script: req('script'),
      items: req('items'),
      total: json['total'] as String?,
      link: json['link'] as String?,
      fields: rawFields.cast<String, String>(),
    );
  }

  /// Serializes in the form [DataRule.fromJson] reads.
  Map<String, Object?> toJson() => {
    'script': script,
    'items': items,
    if (total != null) 'total': total,
    'fields': fields,
    if (link != null) 'link': link,
  };

  /// Reads the vehicles in [doc]'s data block, at most [max]. Returns null
  /// when the block is missing, is not JSON, or has no list at [items]: the
  /// caller then reads the visible cards instead. Values of the wrong type
  /// are skipped, never trusted: the block is page content.
  ({List<VehicleListing> listings, int? total})? read(
    Document doc, {
    required String sourceUrl,
    required DateTime now,
    required int max,
  }) {
    final text = doc.querySelector(script)?.text;
    if (text == null || text.isEmpty) return null;
    final Object? root;
    try {
      root = jsonDecode(text);
    } on FormatException {
      return null;
    }
    final list = _at(root, items);
    if (list is! List) return null;
    final base = Uri.tryParse(sourceUrl);
    final out = <VehicleListing>[];
    for (final raw in list) {
      if (out.length >= max) break;
      if (raw is! Map) continue;
      String? str(String name) => switch (_field(raw, name)) {
        final String s when s.trim().isNotEmpty => s.trim(),
        final num n => '$n',
        _ => null,
      };
      num? number(String name) => switch (_field(raw, name)) {
        final num n => n,
        final String s => num.tryParse(s.replaceAll(RegExp(r'[^\d.]'), '')),
        _ => null,
      };
      final year = number('year')?.toInt();
      final make = str('make');
      final model = str('model');
      final title =
          str('title') ?? [if (year != null) '$year', ?make, ?model, ?str('trim')].join(' ').trim();
      if (title.isEmpty) continue;
      final image = str('image');
      final linkPath = link == null ? null : _fill(link!, raw);
      out.add(
        VehicleListing(
          id: 'v${out.length + 1}',
          title: title,
          sourceUrl: sourceUrl,
          readAt: now,
          price: number('price')?.toDouble(),
          mileage: number('mileage')?.toInt(),
          year: year ?? parseTitle(title)?.year,
          make: make ?? parseTitle(title)?.make,
          model: model ?? parseTitle(title)?.model,
          imageUrl: image != null && image.startsWith('https://') ? image : null,
          detailUrl: linkPath == null || base == null ? null : base.resolve(linkPath).toString(),
        ),
      );
    }
    final t = total == null ? null : _at(root, total!);
    return (listings: out, total: t is num ? t.toInt() : null);
  }

  Object? _field(Map raw, String name) {
    final path = fields[name];
    return path == null ? null : _at(raw, path);
  }

  /// `{key}` placeholders in [template] filled from [item]; a missing or
  /// non-text value leaves the whole link out.
  static String? _fill(String template, Map item) {
    var missing = false;
    final out = template.replaceAllMapped(RegExp(r'\{([\w.-]+)\}'), (m) {
      final v = _at(item, m.group(1)!);
      if (v is String || v is num) return Uri.encodeComponent('$v');
      missing = true;
      return '';
    });
    return missing ? null : out;
  }

  /// The value at dotted [path] under [root], or null.
  static Object? _at(Object? root, String path) {
    Object? cur = root;
    for (final seg in path.split('.')) {
      if (cur is Map) {
        cur = cur[seg];
      } else if (cur is List) {
        final i = int.tryParse(seg);
        cur = i == null || i < 0 || i >= cur.length ? null : cur[i];
      } else {
        return null;
      }
    }
    return cur;
  }
}
