import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/models/model_catalog.dart';
import 'log.dart';
import 'token_store.dart';

/// Where a catalog model is, from the app's point of view.
sealed class ModelStatus {
  const ModelStatus();
}

/// Not on the device.
final class ModelNotInstalled extends ModelStatus {
  const ModelNotInstalled();
}

/// Download in progress, with the percent so far.
final class ModelDownloading extends ModelStatus {
  const ModelDownloading(this.percent);

  final int percent;
}

/// On the device, not loaded into memory.
final class ModelInstalled extends ModelStatus {
  const ModelInstalled();
}

/// Being loaded into memory.
final class ModelLoading extends ModelStatus {
  const ModelLoading();
}

/// Loaded and answering.
final class ModelReady extends ModelStatus {
  const ModelReady();
}

/// A download or load failed; [message] is a sentence for the person.
final class ModelFailed extends ModelStatus {
  const ModelFailed(this.message, {this.needsToken = false});

  final String message;

  /// True when the host answered 401/403: the fix is a token, not a retry.
  final bool needsToken;
}

/// What the app knows about each catalog model, which one is active, and
/// which one it would offer a person who has none.
class ModelsState {
  const ModelsState({required this.statuses, this.activeId, this.recommendedId});

  final Map<String, ModelStatus> statuses;
  final String? activeId;

  /// The catalog model that fits this phone's free memory
  /// ([ModelCatalog.forFreeMemory]); what the conversation offers to
  /// download when nothing is installed.
  final String? recommendedId;

  ModelStatus statusOf(AdvisorModelSpec m) => statuses[m.id] ?? const ModelNotInstalled();

  /// The recommended model's spec, or the catalog default.
  AdvisorModelSpec get recommended =>
      (recommendedId == null ? null : ModelCatalog.byId(recommendedId!)) ??
      ModelCatalog.defaultModel;

  /// True while any model is downloading or loading, so the conversation
  /// can say "getting ready" instead of "no model".
  bool get busy => statuses.values.any((s) => s is ModelDownloading || s is ModelLoading);

  ModelsState copyWith({
    Map<String, ModelStatus>? statuses,
    String? activeId,
    bool clearActive = false,
  }) => ModelsState(
    statuses: statuses ?? this.statuses,
    activeId: clearActive ? null : (activeId ?? this.activeId),
    recommendedId: recommendedId,
  );
}

/// The SDK seam. The real implementation calls `FlutterEdgeAi`; tests supply
/// a fake so the notifier's state machine is testable on the Dart VM.
abstract interface class EdgeAiGateway {
  /// Starts the engine once; later calls are no-ops.
  Future<void> initialize();

  /// Whether the model's file is on the device.
  Future<bool> isInstalled(AdvisorModelSpec spec);

  /// Downloads the model, reporting whole percents; [token] for gated hosts.
  Future<void> install(
    AdvisorModelSpec spec, {
    String? token,
    required void Function(int percent) onProgress,
    CancelToken? cancelToken,
  });

  /// Deletes the model's file.
  Future<void> uninstall(AdvisorModelSpec spec);

  /// Loads an installed model into memory and returns it.
  Future<InferenceModel> load(AdvisorModelSpec spec, {String? token});
}

final class FlutterEdgeAiGateway implements EdgeAiGateway {
  bool _initialized = false;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await FlutterEdgeAi.initialize(inferenceEngines: [LiteRtLmEngine()]);
    _initialized = true;
  }

  @override
  Future<bool> isInstalled(AdvisorModelSpec spec) => FlutterEdgeAi.isModelInstalled(spec.filename);

  @override
  Future<void> install(
    AdvisorModelSpec spec, {
    String? token,
    required void Function(int percent) onProgress,
    CancelToken? cancelToken,
  }) async {
    var builder = FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromNetwork(spec.url, token: token, foreground: true).withProgress(onProgress);
    if (cancelToken != null) builder = builder.withCancelToken(cancelToken);
    await builder.install();
  }

  @override
  Future<void> uninstall(AdvisorModelSpec spec) => FlutterEdgeAi.uninstallModel(spec.filename);

  @override
  Future<InferenceModel> load(AdvisorModelSpec spec, {String? token}) async {
    // `getActiveModel` loads whichever model the SDK last marked active. Re-running
    // the install for an already-downloaded file is the SDK's way to mark it
    // active without copying (mirrors the upstream example's loader). The
    // token rides along so a gated model can be marked active too.
    await FlutterEdgeAi.installModel(
      modelType: spec.modelType,
      fileType: spec.fileType,
    ).fromNetwork(spec.url, token: token).install();
    final maxTokens = await contextWindowFor(spec);
    return FlutterEdgeAi.getActiveModel(
      maxTokens: maxTokens,
      preferredBackend: spec.preferredBackend,
    );
  }
}

final edgeAiGatewayProvider = Provider<EdgeAiGateway>((ref) => FlutterEdgeAiGateway());

final advisorModelServiceProvider = AsyncNotifierProvider<AdvisorModelService, ModelsState>(
  AdvisorModelService.new,
);

/// One instance owns the SDK lifecycle: downloads, the loaded model and the
/// switch between models. No other code touches `FlutterEdgeAi` directly
/// (backlog VA-1.1.1).
final class AdvisorModelService extends AsyncNotifier<ModelsState> {
  /// Sentences for the person; the engine's own text goes to the log.
  static const _downloadFailed = 'The download failed. Check the connection and retry.';
  static const _loadFailed = 'The model could not be loaded. Free some memory and retry.';
  static const _notInstalled = 'Download the model first.';

  InferenceModel? _loaded;

  /// Completes with the model when a load in flight finishes, or with null
  /// when it fails; see [whenLoaded].
  Completer<InferenceModel?>? _loading;

  /// Cancel tokens per model id, so cancelling one download never hits
  /// another.
  final Map<String, CancelToken> _cancels = {};

  /// The loaded model, for the chat layer. Null until [activate] succeeds.
  InferenceModel? get loadedModel => _loaded;

  /// The loaded model, waiting for a load in progress first. Null when
  /// nothing is loaded or loading, so a conversation that starts while the
  /// model is still coming into memory simply waits instead of failing.
  Future<InferenceModel?> whenLoaded() async {
    if (_loaded != null) return _loaded;
    final pending = _loading;
    if (pending != null && !pending.isCompleted) return pending.future;
    return null;
  }

  @override
  Future<ModelsState> build() async {
    final gateway = ref.watch(edgeAiGatewayProvider);
    await gateway.initialize();
    final statuses = <String, ModelStatus>{};
    for (final m in ModelCatalog.all) {
      statuses[m.id] = await gateway.isInstalled(m)
          ? const ModelInstalled()
          : const ModelNotInstalled();
    }
    // Closing at teardown is fire-and-forget: nothing can await a disposed
    // notifier.
    ref.onDispose(() => unawaited(_loaded?.close() ?? Future.value()));
    final recommended = ModelCatalog.forFreeMemory(await availableMemoryGb());
    // An installed model loads without being asked: the default when it is
    // on the phone, otherwise whatever is. Nobody should have to open the
    // Models screen to start a conversation (observed 2026-10-12: the owner
    // chose the model by hand on every launch and found the step baffling).
    // Scheduled after this build settles, since activate() writes state.
    final start = ModelCatalog.all
        .where((m) => statuses[m.id] is ModelInstalled)
        .fold<AdvisorModelSpec?>(null, (best, m) => best ?? m);
    if (start != null) {
      // Created now so a conversation that starts before the timer fires
      // waits on it (see whenLoaded); activate() completes it.
      _loading = Completer<InferenceModel?>();
      unawaited(
        Future<void>.delayed(Duration.zero, () {
          final pending = _loading;
          // Skip when something was activated meanwhile (a test, a tap on
          // the Models screen) or the notifier is gone.
          if (ref.mounted && _loaded == null && pending != null && !pending.isCompleted) {
            unawaited(activate(start));
          } else if (pending != null && !pending.isCompleted) {
            pending.complete(null);
          }
        }),
      );
    }
    return ModelsState(statuses: statuses, recommendedId: recommended.id);
  }

  void _set(AdvisorModelSpec m, ModelStatus s) {
    final current = state.value;
    if (current == null) return;
    state = AsyncData(current.copyWith(statuses: {...current.statuses, m.id: s}));
  }

  /// Downloads [m]; a second call while it is downloading is ignored.
  Future<void> download(AdvisorModelSpec m) async {
    if (_cancels.containsKey(m.id)) return;
    final gateway = ref.read(edgeAiGatewayProvider);
    final token = await _token();
    final cancel = _cancels[m.id] = CancelToken();
    _set(m, const ModelDownloading(0));
    try {
      await gateway.install(
        m,
        token: token,
        onProgress: (p) => _set(m, ModelDownloading(p)),
        cancelToken: cancel,
      );
      _set(m, const ModelInstalled());
      // A model downloaded while nothing is active is the one the person
      // wants to talk to; loading it is the obvious next step, not a second
      // button.
      if (state.value?.activeId == null) await activate(m);
    } on DownloadException catch (e) {
      // 401 and 403 mean a token, not a retry, is the fix.
      final needsToken = e.error is UnauthorizedError || e.error is ForbiddenError;
      logDev('download of ${m.id} failed: $e');
      _set(m, ModelFailed(_downloadFailed, needsToken: needsToken));
    } on Exception catch (e) {
      logDev('download of ${m.id} failed: $e');
      _set(m, cancel.isCancelled ? const ModelNotInstalled() : const ModelFailed(_downloadFailed));
    } finally {
      _cancels.remove(m.id);
    }
  }

  /// Stops the download of [m]; its status returns to not installed.
  void cancelDownload(AdvisorModelSpec m) => _cancels[m.id]?.cancel();

  Future<String?> _token() async {
    final token = await ref.read(tokenStoreProvider).read();
    return (token == null || token.isEmpty) ? null : token;
  }

  Future<void> remove(AdvisorModelSpec m) async {
    final current = state.value;
    if (current?.activeId == m.id) {
      await _loaded?.close();
      _loaded = null;
      state = AsyncData(current!.copyWith(clearActive: true));
    }
    await ref.read(edgeAiGatewayProvider).uninstall(m);
    _set(m, const ModelNotInstalled());
  }

  /// Loads [m] and makes it the model the chat uses. Switching closes the
  /// previous model first (backlog VA-1.2.1). Only an installed model can be
  /// activated.
  Future<void> activate(AdvisorModelSpec m) async {
    final current = state.value;
    if (current == null) return;
    final status = current.statusOf(m);
    if (status is! ModelInstalled && status is! ModelReady && status is! ModelFailed) {
      _set(m, const ModelFailed(_notInstalled));
      return;
    }
    await _loaded?.close();
    _loaded = null;
    final statuses = {...current.statuses};
    if (current.activeId != null && current.activeId != m.id) {
      statuses[current.activeId!] = const ModelInstalled();
    }
    statuses[m.id] = const ModelLoading();
    state = AsyncData(current.copyWith(statuses: statuses, clearActive: true));
    final pending = _loading;
    final loading = pending != null && !pending.isCompleted
        ? pending
        : (_loading = Completer<InferenceModel?>());
    try {
      _loaded = await ref.read(edgeAiGatewayProvider).load(m, token: await _token());
      state = AsyncData(
        current.copyWith(statuses: {...statuses, m.id: const ModelReady()}, activeId: m.id),
      );
      if (!loading.isCompleted) loading.complete(_loaded);
    } on Exception catch (e) {
      logDev('load of ${m.id} failed: $e');
      state = AsyncData(
        current.copyWith(
          statuses: {...statuses, m.id: const ModelFailed(_loadFailed)},
          clearActive: true,
        ),
      );
      if (!loading.isCompleted) loading.complete(null);
    }
  }
}

/// Free memory below which the catalog's window is cut to [_safeWindow],
/// and below which again to [_minimalWindow]. The first number came from
/// the emulator: a 6 GB emulator running Gemma 4 E2B with an 8k window plus
/// a WebView reached 4.8 GB resident and the OS killed the app. Measured on
/// a Galaxy Z Fold 4 (12 GB) on 2026-10-12: the OS reported 4.5 GB available
/// at launch, loading Gemma 4 E2B on the GPU took that to 2.9 GB, and the
/// 4,096 window the old 5.5 GB threshold chose overflowed on the third turn
/// after one page read. 4 GB keeps that phone on the full window.
const _comfortableFreeGb = 4.0;
const _tightFreeGb = 3.0;
const _safeWindow = 4096;
const _minimalWindow = 2048;

/// The context window is memory: the KV cache grows with it. The catalog
/// value is a ceiling, and a device with less room gets a smaller window.
/// Exposed for the gateway and for tests of the thresholds.
Future<int> contextWindowFor(AdvisorModelSpec spec) async {
  final gb = await availableMemoryGb();
  if (gb == null) return spec.maxTokens;
  final window = windowForFreeMemory(gb, ceiling: spec.maxTokens);
  logDev('available memory ${gb.toStringAsFixed(1)} GB -> context $window');
  return window;
}

/// Memory the OS reports as available, in GB, or null where the
/// diagnostics plugin has no answer (tests, desktop).
Future<double?> availableMemoryGb() async {
  try {
    if (!FlutterEdgeAiDiagnostics.isSupported) return null;
    final available = (await FlutterEdgeAiDiagnostics.memorySnapshot()).availableBytes;
    return available == null ? null : available / (1024 * 1024 * 1024);
  } on Exception catch (e) {
    logDev('memory snapshot failed: $e');
    return null;
  }
}

/// The pure part of [contextWindowFor]: the window for [freeGb] of free
/// memory, never above [ceiling].
int windowForFreeMemory(double freeGb, {required int ceiling}) {
  var window = ceiling;
  if (freeGb < _comfortableFreeGb && window > _safeWindow) window = _safeWindow;
  if (freeGb < _tightFreeGb && window > _minimalWindow) window = _minimalWindow;
  return window;
}
