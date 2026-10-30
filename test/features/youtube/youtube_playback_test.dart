import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/youtube/youtube_playback.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.proxyyou/playback');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  Map<String, dynamic> response = {};
  Completer<Map<String, dynamic>>? delayed;
  var calls = 0;
  var shown = 0;
  var cancelled = 0;
  Map<String, dynamic>? arguments;
  Map<String, dynamic> progress = {};
  setUp(() {
    calls = 0;
    shown = 0;
    cancelled = 0;
    arguments = null;
    progress = {};
    delayed = null;
    response = {'status': 'passed', 'seconds': 12.5, 'frames': 120, 'videoId': 'jNQXAC9IVRw'};
    messenger.setMockMessageHandler(
      'flutter/assets',
      (_) async => ByteData.sublistView(Uint8List.fromList(utf8.encode('/* fixture proof */'))),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cancel') {
        cancelled++;
        return null;
      }
      if (call.method == 'show') {
        shown++;
        return null;
      }
      if (call.method == 'progress') return progress;
      calls++;
      arguments = Map<String, dynamic>.from(call.arguments as Map);
      expectSync((call.arguments as Map)['port'], 12334);
      return delayed?.future ?? response;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMessageHandler('flutter/assets', null);
  });
  YoutubePlaybackController controller({bool enabled = true}) {
    final value = YoutubePlaybackController(port: 12334, enabled: enabled);
    addTearDown(value.dispose);
    return value;
  }

  test('valid playback evidence gives passed', () async {
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.passed);
    expect(value.state.frames, 120);
  });
  test('Windows player receives proxy and proof and must return real evidence', () async {
    final value = controller();
    await value.start(
      playbackRunner: (arguments) async {
        expect(arguments['port'], 12334);
        expect(arguments['videoId'], 'jNQXAC9IVRw');
        expect(arguments['script'], '/* fixture proof */');
        expect(arguments['session'], isNotEmpty);
        return response;
      },
    );
    expect(value.state.status, PlaybackStatus.passed);
    expect(calls, 0);
  });
  test('Windows passed flag without rendered frames cannot confirm video', () async {
    final value = controller();
    await value.start(playbackRunner: (_) async => {...response, 'frames': 0});
    expect(value.state.status, PlaybackStatus.failed);
    expect(calls, 0);
  });
  test('eleven seconds cannot confirm playback', () async {
    response['seconds'] = 11.99;
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.failed);
  });
  test('twelve seconds of decoded playback confirms success', () async {
    response['seconds'] = 12;
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.passed);
  });
  test('a passed flag without sufficient playback duration cannot pass', () async {
    response['seconds'] = 0;
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.failed);
  });
  test('clock advancement without frames cannot pass', () async {
    response['frames'] = 0;
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.failed);
  });
  test('another video cannot pass', () async {
    response['videoId'] = 'abcdefghijk';
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.failed);
  });
  test('unsupported platform is explicit', () async {
    response = {'status': 'unsupported'};
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.unsupported);
  });
  test('a disconnected controller does not start a player', () async {
    final value = controller(enabled: false);
    await value.start();
    expect(value.state.status, PlaybackStatus.idle);
    expect(calls, 0);
  });
  test('evidence after disposal cannot change the displayed result', () async {
    final value = YoutubePlaybackController(port: 12334, enabled: true);
    final states = <PlaybackStatus>[];
    value.addListener((state) => states.add(state.status));
    delayed = Completer<Map<String, dynamic>>();
    final run = value.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    value.dispose();
    delayed!.complete(response);
    await run;
    expect(states, isNot(contains(PlaybackStatus.passed)));
  });
  test('nonfinite native proof cannot confirm playback', () async {
    response['seconds'] = double.infinity;
    final value = controller();
    await value.start();
    expect(value.state.status, PlaybackStatus.failed);
  });

  test('percentage uses only decoded continuous duration and is capped before confirmation', () {
    expect(const PlaybackState(PlaybackStatus.checking, seconds: 6, frames: 20).percent, 50);
    expect(const PlaybackState(PlaybackStatus.checking, seconds: 12, frames: 20).percent, 99);
    expect(const PlaybackState(PlaybackStatus.checking, seconds: 6).percent, 0);
    expect(const PlaybackState(PlaybackStatus.checking, seconds: double.infinity, frames: 20).percent, 0);
    expect(const PlaybackState(PlaybackStatus.passed, seconds: 12, frames: 20).percent, 100);
  });

  for (final background in [false, true]) {
    test('real evidence updates progress and a reset returns to zero, background=$background', () async {
      delayed = Completer<Map<String, dynamic>>();
      final value = YoutubePlaybackController(port: 12334, enabled: true, progressEnabled: true);
      final run = value.start(background: background);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(arguments?['background'], background ? true : null);
      final session = arguments!['session'];
      progress = {'session': session, 'videoId': 'jNQXAC9IVRw', 'seconds': 6.0, 'frames': 80};
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(value.state.percent, 50);
      progress = {...progress, 'session': 'stale', 'seconds': 11.0};
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(value.state.percent, 50);
      progress = {...progress, 'session': session, 'seconds': 0.0, 'frames': 0};
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(value.state.percent, 0);
      delayed!.complete(response);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await run;
      expect(value.state.status, PlaybackStatus.passed);
      expect(value.state.percent, 100);
      // Late progress cannot overwrite the final proof.
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(value.state.percent, 100);
      value.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
  }

  test('automatic launch is silent and a manual click promotes the same session', () async {
    delayed = Completer<Map<String, dynamic>>();
    final value = YoutubePlaybackController(port: 12334, enabled: true, automatic: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(calls, 0);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(calls, 1);
    expect(arguments?['background'], true);
    await value.start();
    expect(shown, 1);
    expect(calls, 1);
    delayed!.complete(response);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    value.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('switching routes cancels old progress and starts a new silent session', () async {
    delayed = Completer<Map<String, dynamic>>();
    final old = YoutubePlaybackController(port: 12334, enabled: true, automatic: true, progressEnabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    final oldResult = delayed!;
    final oldSession = arguments!['session'];
    old.dispose();
    delayed = Completer<Map<String, dynamic>>();
    final next = YoutubePlaybackController(port: 12334, enabled: true, automatic: true, progressEnabled: true);
    await Future<void>.delayed(const Duration(milliseconds: 650));
    expect(cancelled, 1);
    expect(calls, 2);
    expect(arguments!['session'], isNot(oldSession));
    expect(next.state.percent, 0);
    progress = {'session': oldSession, 'videoId': 'jNQXAC9IVRw', 'seconds': 11.5, 'frames': 200};
    oldResult.complete(response);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(next.state.percent, 0);
    expect(next.state.status, PlaybackStatus.checking);
    delayed!.complete(response);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(next.state.status, PlaybackStatus.passed);
    next.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test('disconnect before automatic debounce prevents any player launch', () async {
    final value = YoutubePlaybackController(port: 12334, enabled: true, automatic: true);
    value.dispose();
    await Future<void>.delayed(const Duration(seconds: 1));
    expect(calls, 0);
    expect(cancelled, 0);
  });
  for (final background in [false, true]) {
    test('platform callback that never returns times out, background=$background', () async {
      final value = YoutubePlaybackController(
        port: 12334,
        enabled: true,
        playbackTimeout: const Duration(milliseconds: 30),
      );
      final pending = Completer<Map<String, dynamic>?>();
      await value.start(background: background, playbackRunner: (_) => pending.future);
      expect(value.state.status, PlaybackStatus.failed);
      // A proof arriving after timeout cannot turn failure into success.
      pending.complete(response);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(value.state.status, PlaybackStatus.failed);
      value.dispose();
    });
    test('asset loading that never returns is bounded, background=$background', () async {
      final pending = Completer<String>();
      final value = YoutubePlaybackController(
        port: 12334,
        enabled: true,
        playbackTimeout: const Duration(milliseconds: 30),
        scriptLoader: (_) => pending.future,
      );
      await value.start(background: background);
      expect(value.state.status, PlaybackStatus.failed);
      pending.complete('late script');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls, 0);
      expect(value.state.status, PlaybackStatus.failed);
      value.dispose();
    });
  }
  test('each balance rotation restarts the attempt timeout without an overall series limit', () async {
    delayed = Completer<Map<String, dynamic>>();
    final firstResult = delayed!;
    final first = YoutubePlaybackController(
      port: 12334,
      enabled: true,
      playbackTimeout: const Duration(milliseconds: 500),
    );
    final firstRun = first.start(background: true);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    first.dispose();
    delayed = Completer<Map<String, dynamic>>();
    final next = YoutubePlaybackController(
      port: 12334,
      enabled: true,
      playbackTimeout: const Duration(milliseconds: 500),
    );
    final nextRun = next.start(background: true);
    // The old timeout has elapsed, but the new server still has its own full deadline.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(next.state.status, PlaybackStatus.checking);
    delayed!.complete(response);
    await nextRun;
    expect(next.state.status, PlaybackStatus.passed);
    firstResult.complete(response);
    await firstRun;
    next.dispose();
  });
  testWidgets('automatic playback waits for all prerequisites, manual promotion does not start another chain', (
    tester,
  ) async {
    final gate = Completer<bool>();
    var preparations = 0;
    final value = YoutubePlaybackController(
      port: 12334,
      enabled: true,
      scriptLoader: (_) async => 'fixture',
      automatic: true,
      beforePlayback: () {
        preparations++;
        return gate.future;
      },
    );
    addTearDown(value.dispose);
    await tester.pump(const Duration(milliseconds: 600));
    expect(preparations, 1);
    expect(calls, 0);
    await value.start();
    expect(preparations, 1);
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(arguments!['background'], isNull);
    expect(value.state.status, PlaybackStatus.passed);
  });
  for (final throwing in [false, true]) {
    test('failed prerequisite never opens or runs video: throwing=$throwing', () async {
      final value = YoutubePlaybackController(
        port: 12334,
        enabled: true,
        scriptLoader: (_) async => 'fixture',
        beforePlayback: () async {
          if (throwing) throw Exception('failed');
          return false;
        },
      );
      addTearDown(value.dispose);
      await value.start(background: true);
      expect(calls, 0);
      expect(value.state.status, PlaybackStatus.idle);
    });
  }
  testWidgets('full success waits the configured interval, cancellation or failure does not schedule success', (
    tester,
  ) async {
    var repeats = 0;
    var successes = 0;
    final value = YoutubePlaybackController(
      port: 12334,
      enabled: true,
      scriptLoader: (_) async => 'fixture',
      beforePlayback: () async => true,
      onPassed: (_) async {
        successes++;
      },
      onRepeat: () => repeats++,
      interval: () => const Duration(minutes: 17),
    );
    addTearDown(value.dispose);
    unawaited(value.start(background: true));
    await tester.pumpAndSettle();
    expect(successes, 1);
    await tester.pump(const Duration(minutes: 16, seconds: 59));
    expect(repeats, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(repeats, 1);
    expect(calls, 1);
  });
  testWidgets('cached successful balance configuration does not repeat video before expiry', (tester) async {
    var repeats = 0;
    final value = YoutubePlaybackController(
      port: 12334,
      enabled: true,
      scriptLoader: (_) async => 'fixture',
      automatic: true,
      initialState: const PlaybackState(PlaybackStatus.passed, seconds: 12, frames: 294),
      repeatAfter: const Duration(minutes: 3),
      onRepeat: () => repeats++,
    );
    addTearDown(value.dispose);
    await tester.pump(const Duration(minutes: 2, seconds: 59));
    expect(calls, 0);
    expect(value.state.status, PlaybackStatus.passed);
    await tester.pump(const Duration(seconds: 1));
    expect(repeats, 1);
  });
  testWidgets('route disposed during ping or network prerequisites never starts stale video', (tester) async {
    final gate = Completer<bool>();
    final value = YoutubePlaybackController(port: 12334, enabled: true, beforePlayback: () => gate.future);
    final done = value.start(background: true);
    value.dispose();
    gate.complete(true);
    await done;
    expect(calls, 0);
  });
}
