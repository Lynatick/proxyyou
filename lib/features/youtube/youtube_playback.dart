import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hiddify/features/app_based_routing/mac_app_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';
import 'package:hiddify/features/youtube/youtube_test_video.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:hooks_riverpod/legacy.dart';

enum PlaybackStatus { idle, checking, passed, failed, unsupported, cancelled }

class PlaybackState {
  const PlaybackState(this.status, {this.seconds = 0, this.frames = 0, this.videoId});
  final PlaybackStatus status;
  final double seconds;
  final int frames;
  final String? videoId;

  int get percent => status == PlaybackStatus.passed
      ? 100
      : seconds.isFinite && seconds > 0 && frames > 0
      ? (seconds / 12 * 100).floor().clamp(0, 99)
      : 0;
}

final youtubePlaybackSupportedProvider = Provider<bool>((ref) => !PlatformUtils.isWindows);

// Observe the actual server even under balance: its internal switches restart proof.
final youtubePlaybackSelectionProvider = Provider<String?>((ref) {
  final mode = ref.watch(activeRoutingModeProvider);
  final tag = ref.watch(activeProxyNotifierProvider.select((proxy) => proxy.value?.tag));
  if (tag == null || tag.isEmpty) return null;
  return '${mode ?? 'manual'}:$tag';
});

final youtubePlaybackProvider = StateNotifierProvider<YoutubePlaybackController, PlaybackState>((ref) {
  final running = ref.watch(serviceRunningProvider);
  final enabled = ref.watch(ConfigOptions.enableMixedPort);
  final mixedPort = ref.watch(ConfigOptions.mixedPort);
  final port = ref.watch(macDiagnosticPortProvider) ?? mixedPort;
  ref.watch(connectionNotifierProvider.select((value) => value.value?.isConnected));
  ref.watch(activeProfileProvider.select((profile) => profile.value?.id));
  // New selections dispose the previous controller and cancel its native player.
  final route = ref.watch(youtubePlaybackSelectionProvider);
  final mode = ref.watch(activeRoutingModeProvider);
  final sequential = ref.watch(youtubeSequentialVerificationProvider);
  final tag = ref.read(activeProxyNotifierProvider).value?.tag;
  final cache = sequential ? ref.watch(youtubeVerificationCacheProvider) : null;
  final cached = mode == 'balance' && tag != null ? cache?.get(tag) : null;
  YoutubeReport? prepared;
  return YoutubePlaybackController(
    initialState: cached == null
        ? null
        : PlaybackState(PlaybackStatus.passed, seconds: cached.seconds, frames: cached.frames, videoId: cached.videoId),
    repeatAfter: cached == null ? null : cache!.remaining(cached),
    beforePlayback: !sequential
        ? null
        : () async {
            // A manual re-test of a cached proof needs a new native generation.
            if (tag != null && cache?.get(tag) != null) {
              cache!.forget(tag);
              ref.invalidate(youtubeReportProvider);
            }
            prepared = await ref.read(youtubeReportProvider.future);
            return prepared?.configurationTag == tag && prepared?.reachable == true;
          },
    onPassed: !sequential || tag == null
        ? null
        : (proof) async {
            if (prepared != null) await ref.read(youtubeVerificationResultProvider)(prepared!, true);
            if (!ref.mounted) return;
            if (mode == 'balance' && prepared != null) {
              cache!.record(tag, prepared!, proof.seconds, proof.frames, proof.videoId);
            }
          },
    onFailed: cache == null || tag == null
        ? null
        : () async {
            cache.forget(tag);
            if (prepared != null) await ref.read(youtubeVerificationResultProvider)(prepared!, false);
          },
    onRepeat: !sequential
        ? null
        : () {
            ref.invalidate(youtubeReportProvider);
            ref.invalidateSelf();
          },
    interval: () => prepared?.interval ?? const Duration(minutes: 5),
    port: port,
    enabled: running && enabled && ref.watch(youtubePlaybackSupportedProvider),
    automatic: (PlatformUtils.isMacOS || PlatformUtils.isAndroid) && route != null && mode != 'lowest',
    progressEnabled: PlatformUtils.isMacOS || PlatformUtils.isAndroid,
  );
});

class YoutubePlaybackController extends StateNotifier<PlaybackState> {
  YoutubePlaybackController({
    required this.port,
    required this.enabled,
    bool automatic = false,
    this.progressEnabled = false,
    this.playbackTimeout = const Duration(seconds: 100),
    this.scriptLoader,
    this.beforePlayback,
    this.onPassed,
    this.onFailed,
    this.onRepeat,
    this.interval,
    PlaybackState? initialState,
    Duration? repeatAfter,
  }) : super(initialState ?? const PlaybackState(PlaybackStatus.idle)) {
    if (repeatAfter != null) {
      _scheduleRepeat(repeatAfter);
    } else if (automatic && enabled) {
      // Coalesce the selector/group stream while a user changes configurations.
      _automaticStart = Timer(const Duration(milliseconds: 600), () => unawaited(start(background: true)));
    }
  }
  static const _channel = MethodChannel('dev.proxyyou/playback');
  final Future<bool> Function()? beforePlayback;
  final Future<void> Function(PlaybackState)? onPassed;
  final Future<void> Function()? onFailed;
  final void Function()? onRepeat;
  final Duration Function()? interval;
  Timer? _repeat;
  bool _preparing = false;
  void _scheduleRepeat(Duration delay) {
    if (onRepeat == null) return;
    _repeat?.cancel();
    _repeat = Timer(delay > Duration.zero ? delay : Duration.zero, () {
      if (!_disposed) onRepeat!();
    });
  }

  final int port;
  final bool enabled;
  final bool progressEnabled;
  final Duration playbackTimeout;
  final Future<String> Function(String)? scriptLoader;
  Timer? _automaticStart;
  Timer? _progress;
  bool _readingProgress = false;
  bool _background = false;
  String? _session;
  bool _disposed = false;

  Future<void> start({
    String videoId = youtubeTestVideoId,
    bool background = false,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic>)? playbackRunner,
  }) async {
    if (_disposed || !enabled) return;
    _automaticStart?.cancel();
    if (_preparing) {
      if (!background) _background = false;
      return;
    }
    if (state.status == PlaybackStatus.checking) {
      if (!background && _background) {
        try {
          await _channel.invokeMethod<void>('show', {'session': _session}).timeout(const Duration(seconds: 2));
          if (!_disposed) _background = false;
        } on Exception {
          /* The session may have just completed. */
        }
      }
      return;
    }
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) throw ArgumentError.value(videoId, 'videoId');
    _background = background;
    if (beforePlayback != null) {
      _preparing = true;
      var ready = false;
      try {
        ready = await beforePlayback!().timeout(const Duration(seconds: 26));
      } on Exception {
        /* No playback after a failed prerequisite. */
      } finally {
        _preparing = false;
      }
      if (_disposed || !ready) return;
    }
    final session = DateTime.now().microsecondsSinceEpoch.toString();
    _session = session;
    state = const PlaybackState(PlaybackStatus.checking);
    try {
      // Includes asset loading and the platform call: neither may hold the UI forever.
      final response = await _runPlayback(session, videoId, _background, playbackRunner).timeout(playbackTimeout);
      if (_disposed || _session != session) return;
      final seconds = (response?['seconds'] as num?)?.toDouble() ?? 0;
      final frames = (response?['frames'] as num?)?.toInt() ?? 0;
      // A native "passed" flag alone cannot give the UI a successful status.
      final passed =
          response?['status'] == 'passed' &&
          response?['videoId'] == videoId &&
          seconds.isFinite &&
          seconds >= 12 &&
          frames >= 10;
      final status = passed
          ? PlaybackStatus.passed
          : switch (response?['status']) {
              'unsupported' => PlaybackStatus.unsupported,
              'cancelled' => PlaybackStatus.cancelled,
              _ => PlaybackStatus.failed,
            };
      state = PlaybackState(status, seconds: seconds, frames: frames, videoId: videoId);
      if (passed) {
        try {
          await onPassed?.call(state);
        } on Exception {
          /* Stale or unavailable core acknowledgement cannot invalidate decoded proof. */
        }
        if (!_disposed) _scheduleRepeat(interval?.call() ?? const Duration(minutes: 5));
      } else if (status == PlaybackStatus.failed) {
        await _reportFailure();
      }
    } on MissingPluginException {
      if (!_disposed && _session == session) state = const PlaybackState(PlaybackStatus.unsupported);
    } on Exception {
      if (!_disposed && _session == session) {
        state = const PlaybackState(PlaybackStatus.failed);
        await _reportFailure();
      }
      unawaited(_cancel(session));
    } finally {
      if (_session == session) {
        _progress?.cancel();
        _progress = null;
      }
    }
  }

  Future<void> _reportFailure() async {
    try {
      await onFailed?.call();
    } on Exception {
      /* Disconnect or replaced verification generation. */
    }
  }

  Future<Map<String, dynamic>?> _runPlayback(
    String session,
    String videoId,
    bool background,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic>)? playbackRunner,
  ) async {
    final load = scriptLoader ?? rootBundle.loadString;
    final script = await load('assets/playback/proof.js');
    final controls = progressEnabled ? await load('assets/playback/controls.js') : null;
    if (_disposed || _session != session || state.status != PlaybackStatus.checking) return null;
    final arguments = <String, dynamic>{
      'port': port,
      'videoId': videoId,
      'script': script,
      'session': session,
      if (controls != null) 'controls': controls,
      if (background) 'background': true,
    };
    if (progressEnabled) {
      _progress = Timer.periodic(const Duration(milliseconds: 500), (_) => unawaited(_readProgress(session, videoId)));
    }
    return playbackRunner != null
        ? playbackRunner(arguments)
        : _channel.invokeMapMethod<String, dynamic>('start', arguments);
  }

  Future<void> _readProgress(String session, String videoId) async {
    if (_readingProgress || _disposed || _session != session || state.status != PlaybackStatus.checking) return;
    _readingProgress = true;
    try {
      final proof = await _channel
          .invokeMapMethod<String, dynamic>('progress', {'session': session})
          .timeout(const Duration(seconds: 2));
      if (_disposed ||
          _session != session ||
          state.status != PlaybackStatus.checking ||
          proof?['session'] != session ||
          proof?['videoId'] != videoId) {
        return;
      }
      final seconds = (proof?['seconds'] as num?)?.toDouble() ?? 0;
      final frames = (proof?['frames'] as num?)?.toInt() ?? 0;
      state = PlaybackState(
        PlaybackStatus.checking,
        seconds: seconds.isFinite && seconds >= 0 ? seconds : 0,
        frames: frames,
        videoId: videoId,
      );
    } on Exception {
      // Only the final native proof can decide success/failure.
    } finally {
      _readingProgress = false;
    }
  }

  Future<void> _cancel(String session) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'session': session}).timeout(const Duration(seconds: 2));
    } on Exception {
      /* Native view may be gone. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _automaticStart?.cancel();
    _progress?.cancel();
    _repeat?.cancel();
    final session = _session;
    if (session != null) unawaited(_cancel(session));
    super.dispose();
  }
}
