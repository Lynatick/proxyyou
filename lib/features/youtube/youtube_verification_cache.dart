import 'package:hiddify/features/youtube/youtube_probe.dart';

/// Successful proofs are scoped to a connected subscription, never stored on disk.
class VerifiedConfiguration {
  const VerifiedConfiguration(this.report, this.seconds, this.frames, this.videoId, this.expiresAt);
  final YoutubeReport report;
  final double seconds;
  final int frames;
  final String? videoId;
  final DateTime expiresAt;
}

class YoutubeVerificationCache {
  YoutubeVerificationCache({DateTime Function()? now}) : _now = now ?? DateTime.now;
  final DateTime Function() _now;
  final _entries = <String, VerifiedConfiguration>{};
  VerifiedConfiguration? get(String tag) {
    final value = _entries[tag];
    if (value != null && value.expiresAt.isAfter(_now())) return value;
    _entries.remove(tag);
    return null;
  }

  void forget(String tag) => _entries.remove(tag);
  Duration remaining(VerifiedConfiguration value) => value.expiresAt.difference(_now());
  void record(String tag, YoutubeReport report, double seconds, int frames, String? videoId) {
    if (report.configurationTag != tag || !report.reachable || !seconds.isFinite || seconds < 12 || frames < 10) return;
    final interval = report.interval;
    final delay = interval != null && interval > Duration.zero ? interval : const Duration(minutes: 5);
    _entries[tag] = VerifiedConfiguration(report, seconds, frames, videoId, _now().add(delay));
  }
}
