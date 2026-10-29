import 'dart:async';

import 'package:flutter/services.dart';
import 'package:hiddify/features/app_based_routing/mac_app_preferences.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
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
}

final youtubePlaybackSupportedProvider = Provider<bool>((ref) => !PlatformUtils.isWindows);

final youtubePlaybackProvider = StateNotifierProvider.autoDispose<YoutubePlaybackController, PlaybackState>((ref) {
  final running = ref.watch(serviceRunningProvider);
  final enabled = ref.watch(ConfigOptions.enableMixedPort);
  final mixedPort = ref.watch(ConfigOptions.mixedPort);
  final port = ref.watch(macDiagnosticPortProvider) ?? mixedPort;
  ref.watch(connectionNotifierProvider);
  ref.watch(activeProfileProvider.select((profile) => profile.value?.id));
  ref.watch(activeProxyNotifierProvider.select((proxy) => proxy.value?.tag));
  return YoutubePlaybackController(
    port: port,
    enabled: running && enabled && ref.watch(youtubePlaybackSupportedProvider),
  );
});

class YoutubePlaybackController extends StateNotifier<PlaybackState> {
  YoutubePlaybackController({required this.port, required this.enabled})
    : super(const PlaybackState(PlaybackStatus.idle));
  static const _channel = MethodChannel('dev.proxyyou/playback');
  final int port;
  final bool enabled;
  String? _session;
  bool _disposed = false;

  Future<void> start({
    String videoId = youtubeTestVideoId,
    Future<Map<String, dynamic>?> Function(Map<String, dynamic>)? playbackRunner,
  }) async {
    if (!enabled || state.status == PlaybackStatus.checking) return;
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) throw ArgumentError.value(videoId, 'videoId');
    final session = DateTime.now().microsecondsSinceEpoch.toString();
    _session = session;
    state = const PlaybackState(PlaybackStatus.checking);
    try {
      final script = await rootBundle.loadString('assets/playback/proof.js');
      if (_disposed || _session != session) return;
      final arguments = <String, dynamic>{'port': port, 'videoId': videoId, 'script': script, 'session': session};
      final response =
          await (playbackRunner != null
                  ? playbackRunner(arguments)
                  : _channel.invokeMapMethod<String, dynamic>('start', arguments))
              .timeout(const Duration(seconds: 100));
      if (_disposed || _session != session) return;
      final seconds = (response?['seconds'] as num?)?.toDouble() ?? 0;
      final frames = (response?['frames'] as num?)?.toInt() ?? 0;
      // A native "passed" flag alone cannot give the UI a successful status.
      final passed =
          response?['status'] == 'passed' && response?['videoId'] == videoId && seconds >= 12 && frames >= 10;
      final status = passed
          ? PlaybackStatus.passed
          : switch (response?['status']) {
              'unsupported' => PlaybackStatus.unsupported,
              'cancelled' => PlaybackStatus.cancelled,
              _ => PlaybackStatus.failed,
            };
      state = PlaybackState(status, seconds: seconds, frames: frames, videoId: videoId);
    } on MissingPluginException {
      if (!_disposed) state = const PlaybackState(PlaybackStatus.unsupported);
    } on Exception {
      if (!_disposed) state = const PlaybackState(PlaybackStatus.failed);
      unawaited(_cancel(session));
    }
  }

  Future<void> _cancel(String session) async {
    try {
      await _channel.invokeMethod<void>('cancel', {'session': session});
    } on Exception {
      /* Native view may be gone. */
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final session = _session;
    if (session != null) unawaited(_cancel(session));
    super.dispose();
  }
}
