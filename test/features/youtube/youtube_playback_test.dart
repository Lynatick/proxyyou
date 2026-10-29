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
  setUp(() {
    calls = 0;
    delayed = null;
    response = {'status': 'passed', 'seconds': 12.5, 'frames': 120, 'videoId': 'jNQXAC9IVRw'};
    messenger.setMockMessageHandler(
      'flutter/assets',
      (_) async => ByteData.sublistView(Uint8List.fromList(utf8.encode('/* fixture proof */'))),
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'cancel') return null;
      calls++;
      expect((call.arguments as Map)['port'], 12334);
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
}
