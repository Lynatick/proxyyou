import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/hiddifycore/init_signal.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LifecycleProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() =>
      Stream.value(ProfileEntity.local(id: 'profile', active: true, name: 'Test', lastUpdate: DateTime(2026)));
}

class NoHaptics extends HapticService {
  @override
  bool build() => false;
}

class LifecycleRepository implements ConnectionRepository {
  final statuses = BehaviorSubject<ConnectionStatus>.seeded(const Disconnected());
  final actions = <String>[];
  void Function()? onStarted;
  void Function()? onConnecting;
  bool failReconnect = false;

  @override
  bool get coreIsRunning => statuses.value.isConnected;

  @override
  SingboxConfigOption? get configOptionsSnapshot => null;

  @override
  Stream<ConnectionStatus> watchConnectionStatus() => statuses.stream;

  @override
  TaskEither<ConnectionFailure, Unit> setup() => TaskEither.of(unit);

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity profile, bool disableMemoryLimit) => TaskEither(() async {
    actions.add('connect');
    onConnecting?.call();
    statuses.add(const Connecting());
    statuses.add(const Connected());
    onStarted?.call();
    return right(unit);
  });

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => TaskEither(() async {
    actions.add('disconnect');
    statuses.add(const Disconnecting());
    statuses.add(const Disconnected());
    return right(unit);
  });

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity profile, bool disableMemoryLimit) => failReconnect
      ? TaskEither.left(const ConnectionFailure.unexpected('reload failed'))
      : disconnect().flatMap((_) => connect(profile, disableMemoryLimit));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final restartStatusSubscription in [false, true]) {
    test('connection actions remain usable after repeated cycles; restart=$restartStatusSubscription', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final repository = LifecycleRepository();
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
          translationsProvider.overrideWith((ref) => AppLocale.ru.build()),
          connectionRepositoryProvider.overrideWithValue(repository),
          activeProfileProvider.overrideWith(LifecycleProfile.new),
          hapticServiceProvider.overrideWith(NoHaptics.new),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await repository.statuses.close();
      });
      await container.read(sharedPreferencesProvider.future);
      await container.read(translationsProvider.future);
      final profileSubscription = container.listen(activeProfileProvider, (_, next) {});
      addTearDown(profileSubscription.close);
      await container.read(activeProfileProvider.future).timeout(const Duration(seconds: 2));
      final subscription = container.listen(connectionNotifierProvider, (_, next) {});
      addTearDown(subscription.close);
      await container.read(connectionNotifierProvider.future).timeout(const Duration(seconds: 2));
      if (restartStatusSubscription) {
        repository.onStarted = () => container.read(coreRestartSignalProvider.notifier).restart();
      }
      final notifier = container.read(connectionNotifierProvider.notifier);
      repository.onConnecting = () => expect(container.read(connectionNotifierProvider).value, const Connecting());
      for (var cycle = 0; cycle < 3; cycle++) {
        await notifier.toggleConnection().timeout(const Duration(seconds: 2));
        await container.pump();
        expect(await container.read(connectionNotifierProvider.future), const Connected());
        if (cycle == 0) {
          repository.failReconnect = true;
          await notifier.reconnect(await container.read(activeProfileProvider.future));
          await container.pump();
          expect(container.read(connectionNotifierProvider).value, const Connected());
          repository.failReconnect = false;
        }
        await notifier.toggleConnection().timeout(const Duration(seconds: 2));
        await container.pump();
        expect(await container.read(connectionNotifierProvider.future), const Disconnected());
      }
      expect(repository.actions, ['connect', 'disconnect', 'connect', 'disconnect', 'connect', 'disconnect']);
    });
  }

  test('a missing haptic reply cannot block connection controls', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final repository = LifecycleRepository();
    final pendingFeedback = Completer<void>();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') await pendingFeedback.future;
      return null;
    });
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
        connectionRepositoryProvider.overrideWithValue(repository),
        activeProfileProvider.overrideWith(LifecycleProfile.new),
      ],
    );
    addTearDown(() async {
      pendingFeedback.complete();
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      debugDefaultTargetPlatformOverride = null;
      container.dispose();
      await repository.statuses.close();
    });
    await container.read(sharedPreferencesProvider.future);
    container.listen(activeProfileProvider, (_, next) {});
    await container.read(activeProfileProvider.future);
    container.listen(connectionNotifierProvider, (_, next) {});
    await container.read(connectionNotifierProvider.future);
    final notifier = container.read(connectionNotifierProvider.notifier);
    await notifier.toggleConnection().timeout(const Duration(seconds: 1));
    await container.pump();
    await notifier.toggleConnection().timeout(const Duration(seconds: 1));
    expect(repository.actions, ['connect', 'disconnect']);
  });
}
