import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/app_based_routing/mac_app_preferences.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/youtube/youtube_playback.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';
import 'package:hiddify/features/youtube/youtube_verification_cache.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(null);
}

class TestConnection extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => Stream.value(const Connected());
}

class TestActiveProxy extends ActiveProxyNotifier {
  TestActiveProxy(this.updates);
  final Stream<OutboundInfo> updates;
  @override
  Stream<OutboundInfo> build() => updates;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.proxyyou/playback');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late ProviderContainer container;
  late StreamController<OutboundInfo> updates;
  late YoutubeVerificationCache cache;
  late DateTime now;
  final requests = <String>[];
  final players = <String>[];
  var cancellations = 0;
  var frames = 120;
  var issueTicket = false;
  var networkPass = true;
  final completions = <String>[];
  Completer<YoutubeReport>? pending;
  YoutubeReport report(String tag) => YoutubeReport(
    [
      const ProbeResult(label: 'YouTube', outcome: ProbeOutcome.reachable, elapsed: Duration(milliseconds: 12)),
      ProbeResult(
        label: 'Миниатюры',
        outcome: networkPass ? ProbeOutcome.reachable : ProbeOutcome.rejected,
        elapsed: const Duration(milliseconds: 25),
        isThumbnail: true,
      ),
    ],
    configurationTag: tag,
    ticket: issueTicket ? 'ticket-$tag' : null,
    interval: const Duration(minutes: 17),
    ping: const ProbeResult(label: 'Пинг', outcome: ProbeOutcome.reachable, elapsed: Duration(milliseconds: 10)),
  );
  Future<void> select(String tag) async {
    updates.add(OutboundInfo(tag: tag, urlTestDelay: 12));
    await Future<void>.delayed(Duration.zero);
    await container.pump();
    container.read(youtubePlaybackProvider);
    await container.pump();
  }

  setUp(() async {
    requests.clear();
    players.clear();
    cancellations = 0;
    pending = null;
    frames = 120;
    issueTicket = false;
    networkPass = true;
    completions.clear();
    now = DateTime(2026, 10, 29);
    cache = YoutubeVerificationCache(now: () => now);
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    updates = StreamController<OutboundInfo>();
    messenger.setMockMessageHandler(
      'flutter/assets',
      (_) async => ByteData.sublistView(Uint8List.fromList([47, 42, 42, 47])),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'start') return null;
      players.add(container.read(availabilityRouteProvider)!);
      return {'status': 'passed', 'seconds': 12.5, 'frames': frames, 'videoId': 'jNQXAC9IVRw'};
    });
    container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
        serviceRunningProvider.overrideWithValue(true),
        macDiagnosticPortProvider.overrideWith((ref) => 12334),
        activeProfileProvider.overrideWith(TestProfile.new),
        connectionNotifierProvider.overrideWith(TestConnection.new),
        activeRoutingModeProvider.overrideWithValue('balance'),
        activeProxyNotifierProvider.overrideWith(() => TestActiveProxy(updates.stream)),
        youtubeSequentialVerificationProvider.overrideWithValue(true),
        youtubeVerificationCacheProvider.overrideWithValue(cache),
        youtubeVerificationResultProvider.overrideWithValue((report, passed) async {
          if (report.ticket != null) completions.add('${report.configurationTag}:$passed');
        }),
        youtubeAvailabilityRequestProvider.overrideWithValue((tag, sequential) {
          expectSync(sequential, isTrue);
          requests.add(tag);
          return YoutubeAvailabilityRequest(pending?.future ?? Future.value(report(tag)), () async {
            cancellations++;
          });
        }),
      ],
    );
    container.listen(connectionNotifierProvider, (_, _) {});
    container.listen(activeProfileProvider, (_, _) {});
    await container.read(sharedPreferencesProvider.future);
    await container.read(connectionNotifierProvider.future);
    await container.read(activeProfileProvider.future);
    container.listen(youtubePlaybackProvider, (_, _) {});
    container.listen(youtubeReportProvider, (_, _) {});
  });
  tearDown(() async {
    container.dispose();
    await updates.close();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMessageHandler('flutter/assets', null);
  });
  test('real providers reuse full balance proof across a-b-a; expired proof performs the entire chain again', () async {
    await select('a');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    expect(container.read(youtubePlaybackProvider).status, PlaybackStatus.passed);
    expect(cache.get('a'), isNotNull);
    await select('b');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    await select('a');
    expect(container.read(youtubePlaybackProvider).status, PlaybackStatus.passed);
    expect(requests, ['a', 'b']);
    expect(players, ['a', 'b']);
    now = now.add(const Duration(minutes: 17));
    container.invalidate(youtubeReportProvider);
    container.invalidate(youtubePlaybackProvider);
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    expect(requests, ['a', 'b', 'a']);
    expect(players, ['a', 'b', 'a']);
  });
  test('route change during a pending ping/network call cancels it and refuses its stale video', () async {
    pending = Completer<YoutubeReport>();
    await select('a');
    final old = container.read(youtubePlaybackProvider.notifier).start(background: true);
    final blocked = pending!;
    pending = null;
    await select('b');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    blocked.complete(report('a'));
    await old;
    expect(players, ['b']);
    expect(cache.get('a'), isNull);
    expect(cancellations, greaterThanOrEqualTo(1));
  });
  test('new playback failure invalidates previously successful cached proof', () async {
    await select('a');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    expect(cache.get('a'), isNotNull);
    frames = 0;
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    expect(container.read(youtubePlaybackProvider).status, PlaybackStatus.failed);
    expect(cache.get('a'), isNull);
  });
  test('positive ping and YouTube cannot advance a failed thumbnail to video; failure is reported once', () async {
    issueTicket = true;
    networkPass = false;
    await select('a');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    expect(players, isEmpty);
    expect(cache.get('a'), isNull);
    expect(completions, ['a:false']);
  });
  test('failed twelve-second video proof reports the exact configuration and never caches success', () async {
    issueTicket = true;
    frames = 0;
    await select('a');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    expect(completions, ['a:false']);
    expect(container.read(youtubePlaybackProvider).status, PlaybackStatus.failed);
    expect(cache.get('a'), isNull);
  });
  test('full proof reports success and manual re-test requests a fresh native generation', () async {
    issueTicket = true;
    await select('a');
    await container.read(youtubePlaybackProvider.notifier).start(background: true);
    await container.read(youtubePlaybackProvider.notifier).start();
    expect(requests, ['a', 'a']);
    expect(completions, ['a:true', 'a:true']);
  });
}
