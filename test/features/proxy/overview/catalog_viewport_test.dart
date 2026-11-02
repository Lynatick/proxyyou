import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/configuration_catalog.dart';
import 'package:hiddify/features/proxy/overview/catalog_overview_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_page.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../connection/notifier/connection_lifecycle_test.dart' show LifecycleProfile;
import 'catalog_overview_notifier_test.dart' show DelaySort;

void main() {
  testWidgets('grid loads a distant viewport, returns, and retains keyboard focus on unchanged refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final database = ConfigurationCatalog.forTesting(
      NativeDatabase.memory(setup: (db) => db.execute(File('native/database/schema.sql').readAsStringSync())),
    );
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
        translationsProvider.overrideWith((ref) => AppLocale.ru.build()),
        configurationCatalogProvider.overrideWithValue(database),
        serviceRunningProvider.overrideWithValue(false),
        activeProxyGroupsProvider.overrideWith((ref) => Stream.value([])),
        proxiesOverviewNotifierProvider.overrideWith(() => _NoGroups()),
        proxiesSortNotifierProvider.overrideWith(DelaySort.new),
        activeProfileProvider.overrideWith(LifecycleProfile.new),
      ],
    );
    await tester.runAsync(() async {
      await database.customStatement("INSERT INTO subscription_revisions VALUES('r','profile','ready',1,0,'h')");
      await database.customStatement("INSERT INTO subscription_active VALUES('profile','r')");
      await database.customStatement(
        'WITH RECURSIVE ids(i) AS (VALUES(0) UNION ALL SELECT i+1 FROM ids WHERE i<4999) '
        "INSERT INTO configuration_entries SELECT 'r',i,'outbounds',i,printf('server-%05d',i),'socks','SOCKS',0,'h' FROM ids",
      );
      await container.read(sharedPreferencesProvider.future);
      await container.read(translationsProvider.future);
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ProxiesOverviewPage()),
      ),
    );
    await tester.runAsync(() => container.read(catalogOverviewProvider.future));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => container.read(catalogOverviewProvider.notifier).refreshStatus());
    await tester.pump();
    final grid = tester.widget<GridView>(find.byType(GridView));
    grid.controller!.jumpTo(3900 ~/ 2 * 72.0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => container.read(catalogOverviewProvider.notifier).refreshStatus());
    await tester.pump();
    expect(container.read(catalogOverviewProvider).requireValue.offset, greaterThan(3000));
    expect(container.read(catalogOverviewProvider).requireValue.items.length, lessThanOrEqualTo(400));
    expect(find.byType(ProxyTile), findsWidgets);
    grid.controller!.jumpTo(0);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.runAsync(() => container.read(catalogOverviewProvider.notifier).refreshStatus());
    await tester.pump();
    expect(find.text('1. server-00000'), findsOneWidget);
    final focus = Focus.of(tester.element(find.text('1. server-00000')));
    focus.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(focus));
    await tester.runAsync(() => container.read(catalogOverviewProvider.notifier).refreshStatus());
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(focus));
    // A newly tested, formerly unloaded server moves ahead of the focused tile.
    await tester.runAsync(() async {
      await database.customStatement("INSERT INTO configuration_runtime VALUES('profile','r','s',0,1)");
      await database.customStatement("INSERT INTO configuration_status VALUES('r',4999,'s',1,1,5,0,0)");
      await container.read(catalogOverviewProvider.notifier).refreshStatus();
    });
    await tester.pump();
    expect(container.read(catalogOverviewProvider).requireValue.items.first.tag, 'server-04999');
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.runAsync(database.close);
    await tester.pump();
  });
}

class _NoGroups extends ProxiesOverviewNotifier {
  @override
  Stream<OutboundGroup?> build() => Stream.value(null);
}
