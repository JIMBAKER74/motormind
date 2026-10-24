import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'log.dart';

/// Firebase project identifiers, supplied at build time with
/// `--dart-define-from-file=firebase.env` (see `firebase.env.example` and the
/// README section "Analytics and the Firebase key"). Nothing here is committed.
/// When the key is absent the app runs with analytics as a no-op, so a clone
/// builds and runs without any configuration and reports to nobody.
const String _apiKey = String.fromEnvironment('FIREBASE_API_KEY');
const String _appId = String.fromEnvironment('FIREBASE_APP_ID');
const String _senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
const String _projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');

/// True when a Firebase project was supplied at build time.
const bool kAnalyticsEnabled = _apiKey != '' && _appId != '' && _projectId != '';

/// Anonymous event counts only. Parameters are restricted to a short allow
/// list so no free text and no financial value can ever be logged. Every
/// call is fire-and-forget and never throws. Instrumentation of screens and
/// turns lands with VA-7.1.3; today only [init] runs.
abstract interface class Analytics {
  /// Prepares the backend; a no-op when no project was supplied.
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

/// Parameter filtering shared by any real backend, kept apart from the vendor
/// SDK so the privacy rule is testable without one.
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

final class FirebaseAnalyticsService extends AllowListAnalytics {
  FirebaseAnalytics? _fa;

  @override
  Future<void> init() async {
    try {
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: _apiKey,
          appId: _appId,
          messagingSenderId: _senderId,
          projectId: _projectId,
        ),
      );
      _fa = FirebaseAnalytics.instance;
    } on Exception catch (e) {
      // Analytics must never keep the app from starting.
      logDev('analytics unavailable: $e');
    }
  }

  @override
  Future<void> screen(String name) async {
    await _fa?.logScreenView(screenName: name);
  }

  @override
  Future<void> event(String name, {Map<String, Object>? params}) async {
    await _fa?.logEvent(name: name, parameters: filter(name, params));
  }
}

final analyticsProvider = Provider<Analytics>(
  (ref) => kAnalyticsEnabled ? FirebaseAnalyticsService() : NoopAnalytics(),
);
