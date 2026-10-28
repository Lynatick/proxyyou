import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/youtube/youtube_card.dart';
import 'package:hiddify/features/youtube/youtube_playback.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class RecordingPlayback extends YoutubePlaybackController {
  RecordingPlayback() : super(port: 12334, enabled: true);
  int starts = 0;
  @override
  Future<void> start({
    String videoId = 'jNQXAC9IVRw',
    Future<Map<String, dynamic>?> Function(Map<String, dynamic>)? playbackRunner,
  }) {
    starts++;
    return Future.value();
  }
}

void main() {
  testWidgets('availability starts automatically and the heading opens the test player', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final playback = RecordingPlayback();
    var checks = 0;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
        serviceRunningProvider.overrideWithValue(true),
        youtubeReportProvider.overrideWith((ref) {
          checks++;
          return YoutubeReport([
            const ProbeResult(label: 'YouTube', outcome: ProbeOutcome.reachable, elapsed: Duration(milliseconds: 50)),
          ]);
        }),
        youtubePlaybackSupportedProvider.overrideWithValue(true),
        youtubePlaybackProvider.overrideWith((ref) => playback),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: YoutubeCard())),
      ),
    );
    await tester.pumpAndSettle();
    expect(checks, 1);
    expect(playback.starts, 0);
    await tester.tap(find.text('Доступность YouTube'));
    await tester.pumpAndSettle();
    expect(playback.starts, 1);
    expect(checks, 1);
    await tester.tap(find.byTooltip('Проверить ещё раз'));
    await tester.pumpAndSettle();
    expect(checks, 2);
    expect(playback.starts, 1);
  });

  for (final playbackSupported in [false, true]) {
    testWidgets('network probe stays available with playback supported=$playbackSupported', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
          serviceRunningProvider.overrideWithValue(true),
          youtubeReportProvider.overrideWith(
            (ref) => Future.value(
              YoutubeReport([
                const ProbeResult(
                  label: 'YouTube',
                  outcome: ProbeOutcome.reachable,
                  elapsed: Duration(milliseconds: 50),
                ),
              ]),
            ),
          ),
          youtubePlaybackSupportedProvider.overrideWithValue(playbackSupported),
          youtubePlaybackProvider.overrideWith((ref) {
            if (!playbackSupported) throw StateError('Windows must not initialize a player');
            return YoutubePlaybackController(port: 12334, enabled: false);
          }),
        ],
      );
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: SingleChildScrollView(child: YoutubeCard())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('YouTube: 50 мс'), findsOneWidget);
      expect(find.byTooltip('Тестовое видео'), findsOneWidget);
      expect(find.byKey(const ValueKey('youtube-thumbnail')), findsNothing);
      for (final key in ['youtube-result', 'thumbnail-result', 'playback-result']) {
        expect(find.byKey(ValueKey(key)), findsOneWidget);
      }
      expect(find.text('Проверить воспроизведение'), findsNothing);
      expect(find.textContaining('5 секунд'), findsNothing);
      expect(find.textContaining('WebView2'), findsNothing);
      expect(tester.widget<Text>(find.byKey(const ValueKey('youtube-result'))).maxLines, 1);
      final button = tester.widget<TextButton>(
        find.ancestor(of: find.text('Доступность YouTube'), matching: find.byType(TextButton)),
      );
      expect(button.onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('missing thumbnail marks the configuration unavailable despite a positive YouTube result', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final report = YoutubeReport([
      const ProbeResult(label: 'YouTube', outcome: ProbeOutcome.reachable, elapsed: Duration(milliseconds: 50)),
      const ProbeResult(
        label: 'Миниатюры',
        outcome: ProbeOutcome.rejected,
        elapsed: Duration(milliseconds: 70),
        statusCode: 404,
        isThumbnail: true,
      ),
    ]);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
        serviceRunningProvider.overrideWithValue(true),
        youtubeReportProvider.overrideWith((ref) => Future.value(report)),
        youtubePlaybackProvider.overrideWith((ref) => YoutubePlaybackController(port: 12334, enabled: false)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: SingleChildScrollView(child: YoutubeCard())),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Миниатюры: тестовая миниатюра не найдена (HTTP 404)'), findsOneWidget);
    expect(find.textContaining('YouTube: 50 мс'), findsOneWidget);
    expect(find.bySemanticsLabel('Ошибка'), findsOneWidget);
    expect(find.bySemanticsLabel('Успешно'), findsOneWidget);
    expect(find.text('Предварительная проверка сети не пройдена'), findsNothing);
    expect(find.textContaining('Воспроизведение подтверждено'), findsNothing);
  });
}
