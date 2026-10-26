import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/data/configuration_catalog.dart';
import 'package:hiddify/features/proxy/overview/catalog_overview_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../connection/notifier/connection_lifecycle_test.dart' show LifecycleProfile;

class DelaySort extends ProxiesSortNotifier {
  @override
  ProxiesSort build() => ProxiesSort.delay;

  ProxiesSort get sort => state;
  set sort(ProxiesSort value) => state = value;
}

class ObservedCatalog extends ConfigurationCatalog {
  ObservedCatalog()
    : super.forTesting(
        NativeDatabase.memory(setup: (db) => db.execute(File('native/database/schema.sql').readAsStringSync())),
      );
  int rankings = 0;
  Completer<void>? refreshStarted;
  Completer<void>? resumeRefresh;
  bool failRefresh = false;

  @override
  Future<void> refreshOrder(CatalogView view, ProxiesSort sort) {
    rankings++;
    return super.refreshOrder(view, sort);
  }

  @override
  Future<List<OutboundInfo>> refreshPage(
    CatalogView view,
    ProxiesSort sort, {
    required int limit,
    required bool reorder,
  }) async {
    refreshStarted?.complete();
    await resumeRefresh?.future;
    return transaction(() async {
      final items = await super.refreshPage(view, sort, limit: limit, reorder: reorder);
      if (failRefresh) throw StateError('simulated database read error');
      return items;
    });
  }
}

void main() {
  late ObservedCatalog database;
  late ProviderContainer container;

  setUp(() async {
    database = ObservedCatalog();
    await database.customStatement(
      "INSERT INTO subscription_revisions VALUES('revision','profile','ready',1,0,'hash')",
    );
    await database.customStatement("INSERT INTO subscription_active VALUES('profile','revision')");
    await database.customStatement("INSERT INTO configuration_runtime VALUES('profile','revision','session',0,7)");
    await database.transaction(() async {
      for (var index = 0; index < 201; index++) {
        await database.customStatement('INSERT INTO configuration_entries VALUES(?,?,?,?,?,?,?,?,?)', [
          'revision',
          index,
          'outbounds',
          index,
          'server-${index.toString().padLeft(3, '0')}',
          'socks',
          'SOCKS',
          false,
          'hash-$index',
        ]);
      }
    });
    await database.customStatement("INSERT INTO configuration_selections VALUES('profile','select','server-100')");
    container = ProviderContainer(
      overrides: [
        configurationCatalogProvider.overrideWithValue(database),
        serviceRunningProvider.overrideWithValue(true),
        activeProfileProvider.overrideWith(LifecycleProfile.new),
        proxiesSortNotifierProvider.overrideWith(DelaySort.new),
      ],
    );
  });

  tearDown(() async {
    container.dispose();
    await database.close();
  });

  test('ping refresh ranks the whole subscription, retains selection and pages without duplicates', () async {
    container.listen(catalogOverviewProvider, (_, _) {});
    final initial = await container.read(catalogOverviewProvider.future);
    expect(initial.items.first.tag, 'server-000');
    final notifier = container.read(catalogOverviewProvider.notifier);
    await notifier.loadMore();
    expect(container.read(catalogOverviewProvider).requireValue.items.length, 200);
    // The fastest server has not been loaded into the Flutter list yet.
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',200,'session',7,1,10,0,0)");
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',0,'session',7,2,1,1,0)");
    await notifier.refreshStatus();
    final refreshed = container.read(catalogOverviewProvider).requireValue;
    expect(refreshed.items.first.tag, 'server-200');
    expect(refreshed.items.first.urlTestDelay, 10);
    expect(refreshed.selected, 'server-100');
    expect(refreshed.items.length, 200);
    await notifier.loadMore();
    final all = container.read(catalogOverviewProvider).requireValue.items;
    expect(all.length, 201);
    expect(all.map((item) => item.tag).toSet().length, 201);
    expect(all.last.urlTestDelay, 0); // untested follows failed results, as before
    expect(all.firstWhere((item) => item.tag == 'server-000').urlTestDelay, 65535);
  });

  test('a later ping and network invalidation change the order without reopening the list', () async {
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',0,'session',7,1,100,0,0)");
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',1,'session',7,2,200,0,0)");
    container.listen(catalogOverviewProvider, (_, _) {});
    await container.read(catalogOverviewProvider.future);
    final notifier = container.read(catalogOverviewProvider.notifier);
    await notifier.refreshStatus();
    await database.customStatement('UPDATE configuration_status SET delay=5,sequence=3 WHERE entry_id=1');
    await notifier.refreshStatus();
    expect(container.read(catalogOverviewProvider).requireValue.items.first.tag, 'server-001');
    await database.customStatement('UPDATE configuration_runtime SET network_epoch=8');
    await notifier.refreshStatus();
    final reset = container.read(catalogOverviewProvider).requireValue;
    expect(reset.items.first.tag, 'server-000');
    expect(reset.items.every((item) => item.urlTestDelay == 0), isTrue);
  });

  test('reopening reads the latest ping order and releases the previous view', () async {
    final subscription = container.listen(catalogOverviewProvider, (_, _) {});
    await container.read(catalogOverviewProvider.future);
    subscription.close();
    await container.pump();
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',200,'session',7,1,10,0,0)");
    container.listen(catalogOverviewProvider, (_, _) {});
    final reopened = await container.read(catalogOverviewProvider.future);
    expect(reopened.items.first.tag, 'server-200');
    final rows = await database.customSelect('SELECT count(*) AS n FROM configuration_revision_leases').getSingle();
    expect(rows.read<int>('n'), 1);
  });

  test('unchanged results and traffic updates do not trigger another delay ranking', () async {
    container.listen(catalogOverviewProvider, (_, _) {});
    await container.read(catalogOverviewProvider.future);
    final notifier = container.read(catalogOverviewProvider.notifier);
    await notifier.refreshStatus();
    final rankings = database.rankings;
    await notifier.refreshStatus();
    await database.customStatement("INSERT INTO configuration_usage VALUES('revision',200,'session',100,1000)");
    await notifier.refreshStatus();
    expect(database.rankings, rankings);
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',200,'session',7,1,10,0,0)");
    await notifier.refreshStatus();
    expect(database.rankings, rankings + 1);
  });

  for (final sort in [ProxiesSort.name, ProxiesSort.unsorted]) {
    test('ping keeps the chosen $sort sorting mode', () async {
      final sorting = container.read(proxiesSortNotifierProvider.notifier) as DelaySort;
      sorting.sort = sort;
      expect(sorting.sort, sort);
      container.listen(catalogOverviewProvider, (_, _) {});
      await container.read(catalogOverviewProvider.future);
      await database.customStatement("INSERT INTO configuration_status VALUES('revision',200,'session',7,1,10,0,0)");
      await container.read(catalogOverviewProvider.notifier).refreshStatus();
      expect(container.read(catalogOverviewProvider).requireValue.items.first.tag, 'server-000');
    });
  }

  test('pagination waits for ranking, and failed refresh rolls back the SQL order', () async {
    container.listen(catalogOverviewProvider, (_, _) {});
    final initial = await container.read(catalogOverviewProvider.future);
    final notifier = container.read(catalogOverviewProvider.notifier);
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',200,'session',7,1,10,0,0)");
    database.refreshStarted = Completer<void>();
    database.resumeRefresh = Completer<void>();
    database.failRefresh = true;
    final refreshing = notifier.refreshStatus();
    await database.refreshStarted!.future;
    await notifier.loadMore();
    expect(container.read(catalogOverviewProvider).requireValue.items.length, 100);
    database.resumeRefresh!.complete();
    await refreshing;
    expect(container.read(catalogOverviewProvider).requireValue.items.first.tag, 'server-000');
    expect((await database.page(initial.view, offset: 0)).first.tag, 'server-000');
    database.refreshStarted = null;
    database.resumeRefresh = null;
    database.failRefresh = false;
    await notifier.refreshStatus();
    expect(container.read(catalogOverviewProvider).requireValue.items.first.tag, 'server-200');
  });

  test('closing during refresh does not recreate a disposed SQL view or lease', () async {
    final subscription = container.listen(catalogOverviewProvider, (_, _) {});
    await container.read(catalogOverviewProvider.future);
    database.refreshStarted = Completer<void>();
    database.resumeRefresh = Completer<void>();
    final refreshing = container.read(catalogOverviewProvider.notifier).refreshStatus();
    await database.refreshStarted!.future;
    subscription.close();
    await container.pump();
    // Drain the unawaited view cleanup before the delayed refresh resumes.
    await database.customSelect('SELECT count(*) FROM configuration_revision_leases').get();
    database.resumeRefresh!.complete();
    await refreshing;
    for (final table in ['configuration_view_rows', 'configuration_revision_leases']) {
      final row = await database.customSelect('SELECT count(*) AS n FROM $table').getSingle();
      expect(row.read<int>('n'), 0);
    }
  });

  test('the periodic refresh changes the order without a button press', () async {
    final updated = Completer<void>();
    container.listen(catalogOverviewProvider, (_, next) {
      if (next.value?.items.first.tag == 'server-200' && !updated.isCompleted) updated.complete();
    });
    await container.read(catalogOverviewProvider.future);
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',200,'session',7,1,10,0,0)");
    await updated.future.timeout(const Duration(seconds: 5));
  });
}
