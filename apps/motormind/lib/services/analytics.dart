import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log.dart';

/// Compile-time switch (backlog VA-7.1.3). Demo builds pass nothing and ship the
/// no-op. A store flavor would pass `--dart-define=MOTORMIND_ANALYTICS=true`
/// and bind a real backend here; none is bundled with the demo, so no vendor
/// configuration or API key lives in this repository.
const bool kAnalyticsEnabled = bool.fromEnvironment('MOTORMIND_ANALYTICS');

/// Anonymous event counts only. Parameters are restricted to a short allow
/// list so no free text and no financial value can ever be logged. Every
/// call is fire-and-forget and never throws. Instrumentation of screens and
/// turns lands with VA-7.1.3; today only [init] runs.
abstract interface class Analytics {
  /// Prepares the backend; a no-op in demo builds.
  Future<void> init();

  /// Records a screen view by name.
  Future<void> screen(String name);

  /// Records an event; parameters outside the allow list are dropped.
  Future<void> event(String name, {Map<String, Object>? params});
}

final class NoopAnalytics implements Analytics {
  @override
  Future<void> init() async {}

  @override
  Future<void> screen(String name) async {}

  @override
  Future<void> event(String name, {Map<String, Object>? params}) async {}
}

/// Parameter filtering shared by any real backend. Kept separate from the
/// vendor SDK so the privacy rule is testable without one.
abstract base class AllowListAnalytics implements Analytics {
  static const Set<String> allowedParams = {
    'tool',
    'model_id',
    'component',
    'surface',
    'outcome',
    'mode',
    'from',
    'to',
  };

  /// Numbers are refused outright: a financial value must never reach
  /// analytics, and a bucketed string is the only allowed shape.
  Map<String, Object> filter(String name, Map<String, Object>? params) {
    final safe = <String, Object>{
      for (final e in (params ?? const {}).entries)
        if (allowedParams.contains(e.key) && e.value is! num) e.key: e.value,
    };
    if (params != null && safe.length != params.length) {
      logDev('analytics: dropped disallowed params from "$name"');
    }
    return safe;
  }
}

final analyticsProvider = Provider<Analytics>((ref) => NoopAnalytics());
