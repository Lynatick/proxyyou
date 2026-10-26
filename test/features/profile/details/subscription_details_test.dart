import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/notification/in_app_notification_controller.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/details/json_editor.dart';
import 'package:hiddify/features/profile/details/profile_details_notifier.dart';
import 'package:hiddify/features/profile/details/profile_details_page.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:toastification/toastification.dart';

class SilentNotifications extends InAppNotificationController {
  @override
  ToastificationItem? showSuccessToast(String message, {ToastAction? action}) => null;
}

class TestProfiles implements ProfileRepository {
  final ProfileEntity profile = ProfileEntity.remote(
    id: 'subscription',
    active: true,
    name: 'Подписка',
    url: 'https://example.com/sub',
    lastUpdate: DateTime(2026),
  );
  final raw = '{"outbounds":[],"dns":{"servers":[{"tag":"keep"}]},"route":{"rules":[]},"extra":"данные"}';
  int reads = 0;
  String? saved;
  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) => TaskEither.right(profile);
  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) {
    reads++;
    return TaskEither.right(raw);
  }

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String content) {
    saved = content;
    return TaskEither.right(unit);
  }

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) =>
      throw StateError('Editing subscription must not generate a config');
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('editing subscription metadata never reads or rewrites configuration contents', () async {
    final repo = TestProfiles();
    final container = ProviderContainer(
      overrides: [
        profileRepositoryProvider.overrideWith((ref) => Future.value(repo)),
        translationsProvider.overrideWith((ref) => AppLocale.ru.build()),
        inAppNotificationControllerProvider.overrideWithValue(SilentNotifications()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(profileRepositoryProvider.future);
    final provider = profileDetailsNotifierProvider('subscription');
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    final details = await container.read(provider.future);
    expect(details.configContent, isEmpty);
    expect(repo.reads, 0);
    container.read(provider.notifier).setUserOverride(const UserOverride(name: 'Новое имя'));
    expect(await container.read(provider.notifier).save(), isTrue);
    expect(repo.reads, 0);
    expect(repo.saved, '');
  });
  testWidgets('subscription form hides the config editor and disables refresh by default', (tester) async {
    final repo = TestProfiles();
    final container = ProviderContainer(
      overrides: [
        profileRepositoryProvider.overrideWith((ref) => Future.value(repo)),
        translationsProvider.overrideWith((ref) => AppLocale.ru.build()),
      ],
    );
    addTearDown(container.dispose);
    await tester.runAsync(() async {
      await container.read(profileRepositoryProvider.future);
      await container.read(translationsProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ProfileDetailsPage(id: 'subscription')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(JsonEditor), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, isTrue);
    expect(repo.reads, 0);
    expect(tester.takeException(), isNull);
  });
}
