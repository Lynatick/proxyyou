import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/bootstrap.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/chain/model/chain_enum.dart';
import 'package:hiddify/features/chain/notifier/chain_profile_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StartupProfileSource implements ProfileDataSource {
  final profiles = StreamController<ProfileEntity?>();

  @override
  Stream<ProfileEntity?> watchActiveProfile() => profiles.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class StartupProfileRepository implements ProfileRepository {
  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) =>
      TaskEither.right(ProfileEntity.local(id: id, active: true, name: 'Selected profile', lastUpdate: DateTime(2026)));

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late StartupProfileSource source;
  late ProviderContainer container;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    source = StartupProfileSource();
    container = ProviderContainer(
      retry: (retryCount, error) => null,
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
        profileDataSourceProvider.overrideWithValue(source),
        profileRepositoryProvider.overrideWith((ref) => Future.value(StartupProfileRepository())),
      ],
    );
    await container.read(sharedPreferencesProvider.future);
    await container.read(profileRepositoryProvider.future);
  });

  tearDown(() async {
    container.dispose();
    await source.profiles.close();
  });

  test('startup resumes an unread profile stream and accepts an empty database', () async {
    // This is the original bootstrap sequence: reading .future leaves the
    // underlying stream paused, including its first null value from Drift.
    final pending = container.read(activeProfileProvider.future);
    source.profiles.add(null);
    await expectLater(pending.timeout(const Duration(milliseconds: 20)), throwsA(isA<TimeoutException>()));

    await initializeStartupProfiles(container, timeout: const Duration(seconds: 1));

    expect(container.read(activeProfileProvider).requireValue, isNull);
    for (final type in ChainType.values) {
      expect(container.read(chainProfileNotifierProvider(type)).requireValue, isNull);
    }
  });

  test('startup completes for a selected profile and keeps following profile changes', () async {
    final ready = initializeStartupProfiles(container, timeout: const Duration(seconds: 1));
    source.profiles.add(
      ProfileEntity.local(id: 'selected', active: true, name: 'Selected profile', lastUpdate: DateTime(2026)),
    );
    await ready;

    expect(container.read(activeProfileProvider).requireValue?.id, 'selected');
    for (final type in ChainType.values) {
      expect(container.read(chainProfileNotifierProvider(type)).requireValue?.id, 'selected');
    }

    source.profiles.add(null);
    await container.pump();
    expect(container.read(activeProfileProvider).requireValue, isNull);
  });

  test('a stalled profile source cannot block startup indefinitely', () async {
    await expectLater(
      initializeStartupProfiles(container, timeout: const Duration(milliseconds: 20)),
      throwsA(isA<TimeoutException>()),
    );
  });
}
