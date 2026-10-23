import 'dart:convert';
import 'dart:io';

import 'package:advisor_core/advisor_core.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../services/log.dart';

/// Where remembered listings are kept. Tests inject a temp directory.
final listingCacheDirProvider = FutureProvider<Directory>((ref) async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory('${docs.path}/listings');
});

final listingCacheProvider = Provider<ListingCache>(FileListingCache.new);

/// The listings read from each site, kept between launches, so the app
/// opens on what the person last saw (each tile says how old it is) while
/// the fresh read runs, and so a photo once seen is never lost to a read
/// that did not carry it. Public inventory only: titles, prices, miles,
/// photo and detail addresses. Nothing about the person is stored here.
abstract class ListingCache {
  /// Most listings remembered per site; a results page holds 20 to 30, so
  /// this is a few pages' worth.
  static const maxPerSite = 120;

  /// The listings remembered for [siteId], newest read first; empty when
  /// none are or they cannot be read.
  Future<List<VehicleListing>> load(String siteId);

  /// Remembers [fresh] for [siteId] ahead of what was remembered before,
  /// one entry per listing (see [keyOf]), at most [maxPerSite]. A fresh
  /// listing without a photo keeps the photo it was remembered with.
  Future<void> save(String siteId, List<VehicleListing> fresh);

  /// [fresh] merged ahead of [old] under the rules [save] describes.
  static List<VehicleListing> merge(List<VehicleListing> fresh, List<VehicleListing> old) {
    final merged = withRememberedPhotos(fresh, old);
    final keys = merged.map(keyOf).toSet();
    return [...merged, ...old.where((l) => !keys.contains(keyOf(l)))].take(maxPerSite).toList();
  }

  /// One listing's identity across reads: its detail page when known (it
  /// carries the VIN on EchoPark), else title, price and miles. The price is
  /// left out of the detail-page key on purpose: a price drop is the same car.
  static String keyOf(VehicleListing l) => l.detailUrl ?? l.dedupeKey;

  /// [fresh] with photos filled in from [remembered] where a fresh listing
  /// has none and the same car was remembered with one.
  static List<VehicleListing> withRememberedPhotos(
    List<VehicleListing> fresh,
    List<VehicleListing> remembered,
  ) {
    final photos = {
      for (final r in remembered)
        if (r.imageUrl != null) keyOf(r): r.imageUrl!,
    };
    return [
      for (final l in fresh)
        if (l.imageUrl == null && photos[keyOf(l)] != null)
          VehicleListing.fromJson({...l.toJson(), 'imageUrl': photos[keyOf(l)]})
        else
          l,
    ];
  }
}

/// The app's cache: one JSON file per site in the documents folder.
final class FileListingCache extends ListingCache {
  FileListingCache(this._ref);

  final Ref _ref;

  Future<File> _file(String siteId) async {
    final dir = await _ref.read(listingCacheDirProvider.future);
    return File('${dir.path}/$siteId.json');
  }

  @override
  Future<List<VehicleListing>> load(String siteId) async {
    try {
      final f = await _file(siteId);
      if (!await f.exists()) return const [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return const [];
      return [
        for (final e in raw)
          if (e is Map) VehicleListing.fromJson(e.cast<String, Object?>()),
      ];
    } on Exception catch (e) {
      logDev('listing cache unreadable: $e');
      return const [];
    }
  }

  @override
  Future<void> save(String siteId, List<VehicleListing> fresh) async {
    if (fresh.isEmpty) return;
    try {
      final all = ListingCache.merge(fresh, await load(siteId));
      final f = await _file(siteId);
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode([for (final l in all) l.toJson()]));
    } on Exception catch (e) {
      logDev('listing cache not saved: $e');
    }
  }
}

/// A cache that lives for the process, for tests (file I/O does not
/// complete inside a widget test's fake clock).
final class MemoryListingCache extends ListingCache {
  final Map<String, List<VehicleListing>> bySite = {};

  @override
  Future<List<VehicleListing>> load(String siteId) async => bySite[siteId] ?? const [];

  @override
  Future<void> save(String siteId, List<VehicleListing> fresh) async {
    if (fresh.isEmpty) return;
    bySite[siteId] = ListingCache.merge(fresh, bySite[siteId] ?? const []);
  }
}

/// Builds a listing photo. A disk-cached network image in the app; tests
/// replace it, since the disk cache needs platform plugins.
final listingPhotoProvider = Provider<Widget Function(String url, {double? height})>(
  (ref) =>
      (url, {height}) => CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        height: height,
        errorWidget: (_, _, _) => const SizedBox.shrink(),
      ),
);
