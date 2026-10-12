import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app/app.dart';
import 'app/prefs.dart';
import 'features/chat/chat_strings.dart';
import 'services/analytics.dart';
import 'services/log.dart';

/// Bootstraps preferences and analytics before the first frame. Analytics is
/// a no-op in demo builds, so the await costs nothing there; in the store
/// flavor Firebase must be ready before any event is sent.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // A widget that fails to build shows one sentence in its place and the
  // rest of the app keeps working; the error goes to the developer log.
  // Flutter's default is a red screen with the assertion text, which told
  // the owner nothing and took the stage with it (2026-10-12).
  ErrorWidget.builder = (details) {
    logDev('widget failed: ${details.exceptionAsString()}');
    return const _PartBroke();
  };
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  await container.read(analyticsProvider).init();
  runApp(UncontrolledProviderScope(container: container, child: const MotormindApp()));
}

/// What stands in for a part of the screen that hit a bug.
class _PartBroke extends StatelessWidget {
  const _PartBroke();

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Text(
        ChatStrings.partBroke,
        key: const Key('part-broke'),
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ),
  );
}
