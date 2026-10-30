import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_verification_cache.dart';

void main() {
  var now = DateTime(2026, 10, 29);
  late YoutubeVerificationCache cache;
  setUp(() {
    now = DateTime(2026, 10, 29);
    cache = YoutubeVerificationCache(now: () => now);
  });
  YoutubeReport report({String tag = 'a', bool good = true, Duration interval = const Duration(minutes: 17)}) =>
      YoutubeReport(
        [
          const ProbeResult(label: 'YouTube', outcome: ProbeOutcome.reachable, elapsed: Duration(milliseconds: 12)),
          ProbeResult(
            label: 'Миниатюры',
            outcome: good ? ProbeOutcome.reachable : ProbeOutcome.rejected,
            elapsed: const Duration(milliseconds: 35),
            isThumbnail: true,
          ),
        ],
        configurationTag: tag,
        interval: interval,
      );
  test('complete proof survives balance a-b-a and expires at subscription interval from playback success', () {
    cache.record('a', report(), 12.5, 294, 'jNQXAC9IVRw');
    expect(cache.get('b'), isNull);
    now = now.add(const Duration(minutes: 16, seconds: 59));
    expect(cache.get('a')!.seconds, 12.5);
    expect(cache.remaining(cache.get('a')!), const Duration(seconds: 1));
    now = now.add(const Duration(seconds: 1));
    expect(cache.get('a'), isNull);
  });
  test('bad prerequisites, wrong tag, clock-only and insufficient duration cannot enter cache', () {
    cache.record('a', report(good: false), 12, 100, 'jNQXAC9IVRw');
    expect(cache.get('a'), isNull);
    cache.record('a', report(tag: 'b'), 12, 100, 'jNQXAC9IVRw');
    cache.record('a', report(), 11.99, 100, 'jNQXAC9IVRw');
    cache.record('a', report(), 12, 0, 'jNQXAC9IVRw');
    cache.record('a', report(), double.nan, 100, 'jNQXAC9IVRw');
    expect(cache.get('a'), isNull);
  });
  test('zero interval uses the same five minute fallback as the native monitor', () {
    cache.record('a', report(interval: Duration.zero), 12, 100, 'jNQXAC9IVRw');
    expect(cache.remaining(cache.get('a')!), const Duration(minutes: 5));
  });
}
