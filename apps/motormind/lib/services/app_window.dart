import 'package:flutter/services.dart';

/// The native side of [sendToBackground], in `MainActivity.kt`.
const appWindowChannel = MethodChannel('motormind/app');

/// Puts the app behind the launcher, as Home does. Android's Back on the
/// first screen otherwise finishes the activity, and the conversation with
/// it; the model session would also have to be built again on return.
Future<void> sendToBackground() => appWindowChannel.invokeMethod<void>('moveToBackground');
