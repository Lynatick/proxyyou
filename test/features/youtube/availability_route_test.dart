import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/youtube/youtube_playback.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ChangingActiveProxy extends ActiveProxyNotifier {
  ChangingActiveProxy(this.updates);
  final Stream<OutboundInfo> updates;
  @override
  Stream<OutboundInfo> build() => updates;
}

void main() {
  for (final mode in <String?>['balance', null]) {
    test('availability follows manual selection but does not restart on every balance connection: $mode', () async {
      final updates = StreamController<OutboundInfo>();
      final container = ProviderContainer(
        overrides: [
          youtubeSequentialVerificationProvider.overrideWithValue(false),
          activeRoutingModeProvider.overrideWithValue(mode),
          activeProxyNotifierProvider.overrideWith(() => ChangingActiveProxy(updates.stream)),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await updates.close();
      });
      final selections = <String?>[];
      final selectionSubscription = container.listen(
        youtubePlaybackSelectionProvider,
        (_, next) => selections.add(next),
        fireImmediately: true,
      );
      addTearDown(selectionSubscription.close);
      final routes = <String?>[];
      final subscription = container.listen(
        availabilityRouteProvider,
        (_, next) => routes.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);
      updates.add(OutboundInfo(tag: 'a', urlTestDelay: 12));
      await container.pump();
      expect(container.read(availabilityRouteProvider), mode == 'balance' ? 'balance' : 'a');
      expect(container.read(youtubePlaybackSelectionProvider), '${mode ?? 'manual'}:a');
      updates.add(OutboundInfo(tag: 'b', urlTestDelay: 24));
      await container.pump();
      expect(container.read(availabilityRouteProvider), mode == 'balance' ? 'balance' : 'b');
      expect(container.read(youtubePlaybackSelectionProvider), '${mode ?? 'manual'}:b');
      expect(routes, mode == 'balance' ? [null, 'balance'] : [null, 'a', 'b']);
      expect(selections, [null, '${mode ?? 'manual'}:a', '${mode ?? 'manual'}:b']);
      // Ping-only updates do not restart playback.
      updates.add(OutboundInfo(tag: 'b', urlTestDelay: 30));
      await container.pump();
      expect(selections.length, 3);
    });
  }
  test('sequential balance follows each actual configuration and ignores ping-only changes', () async {
    final updates = StreamController<OutboundInfo>();
    final container = ProviderContainer(
      overrides: [
        youtubeSequentialVerificationProvider.overrideWithValue(true),
        activeRoutingModeProvider.overrideWithValue('balance'),
        activeProxyNotifierProvider.overrideWith(() => ChangingActiveProxy(updates.stream)),
      ],
    );
    final routes = <String?>[];
    container.listen(availabilityRouteProvider, (_, next) => routes.add(next), fireImmediately: true);
    updates.add(OutboundInfo(tag: 'a', urlTestDelay: 12));
    await container.pump();
    container.read(availabilityRouteProvider);
    updates.add(OutboundInfo(tag: 'b', urlTestDelay: 20));
    await container.pump();
    container.read(availabilityRouteProvider);
    updates.add(OutboundInfo(tag: 'b', urlTestDelay: 30));
    await container.pump();
    container.read(availabilityRouteProvider);
    expect(routes, [null, 'a', 'b']);
    container.dispose();
    await updates.close();
  });
}
