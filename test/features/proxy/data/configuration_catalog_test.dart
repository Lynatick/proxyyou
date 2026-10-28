import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/proxy/data/configuration_catalog.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CatalogTestDirectories extends AppDirectories {
  CatalogTestDirectories(this.directory);
  final Directory directory;
  @override
  Future<Directories> build() async => (baseDir: directory, workingDir: directory, tempDir: directory);
}

void main() {
  ConfigurationCatalog memory() => ConfigurationCatalog.forTesting(
    NativeDatabase.memory(setup: (database) => database.execute(File('native/database/schema.sql').readAsStringSync())),
  );

  test('SQL pages keep their order and focus while live checks change; errors veto a positive ping', () async {
    final database = memory();
    addTearDown(database.close);
    await database.customStatement(
      "INSERT INTO subscription_revisions VALUES('revision','profile','ready',1,0,'hash')",
    );
    await database.customStatement("INSERT INTO subscription_active VALUES('profile','revision')");
    await database.customStatement("INSERT INTO configuration_runtime VALUES('profile','revision','session',0,7)");
    await database.transaction(() async {
      for (var index = 0; index < 1201; index++) {
        await database.customStatement('INSERT INTO configuration_entries VALUES(?,?,?,?,?,?,?,?,?)', [
          'revision',
          index,
          'outbounds',
          index,
          'server-$index',
          'socks',
          'SOCKS',
          false,
          'hash-$index',
        ]);
      }
    });
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',0,'session',7,1,20,1,0)");
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',1,'session',6,1,10,0,0)");
    await database.customStatement("INSERT INTO configuration_usage VALUES('revision',2,'session',100,250)");
    final view = await database.createView('profile', ProxiesSort.unsorted, connected: true);
    expect(view.count, 1201);
    final first = await database.page(view, offset: 0);
    expect(first.length, 100);
    expect(first.first.tagDisplay, '1. server-0');
    expect(await database.numberedName('profile', 'server-1200', connected: true), '1201. server-1200');
    final reverse = await database.createView('profile', ProxiesSort.unsorted, connected: true, reversed: true);
    final reversedTags = <String>[];
    for (var offset = 0; offset < reverse.count; offset += 100) {
      reversedTags.addAll((await database.page(reverse, offset: offset)).map((item) => item.tag));
    }
    expect(reversedTags.length, 1201);
    expect(reversedTags.toSet().length, 1201);
    expect(reversedTags.first, 'server-1200');
    expect(reversedTags.last, 'server-0');
    expect((await database.page(reverse, offset: 0)).first.tagDisplay, '1201. server-1200');
    await database.dropView(reverse);
    expect(first.first.urlTestDelay, 65535);
    expect(first[1].urlTestDelay, 0); // previous network, not a current result
    expect(first[2].download.toInt(), 250);
    await database.customStatement("UPDATE configuration_status SET delay=1,unavailable=0 WHERE entry_id=0");
    final tags = <String>[];
    for (var offset = 0; offset < view.count; offset += 100) {
      tags.addAll((await database.page(view, offset: offset)).map((item) => item.tag));
    }
    expect(tags.toSet().length, 1201);
    expect(tags.first, 'server-0');
    expect(tags.last, 'server-1200');
    await database.selectConfiguration(view, 'balance');
    expect(await database.selectedTag('profile'), 'balance');
    final usage = await database.createView('profile', ProxiesSort.usage, connected: true);
    expect((await database.page(usage, offset: 0)).first.tag, 'server-2');
    expect((await database.page(usage, offset: 0)).first.tagDisplay, '3. server-2');
    await database.refreshOrder(usage, ProxiesSort.usage, reversed: true);
    expect((await database.page(usage, offset: 1200)).single.tag, 'server-2');
    await database.dropView(usage);
    await database.customStatement("DELETE FROM subscription_active WHERE profile_id='profile'");
    await database.customStatement("UPDATE subscription_revisions SET state='deleted' WHERE id='revision'");
    expect((await database.page(view, offset: 0)).length, 100);
    await database.dropView(view);
    expect(
      (await database.customSelect('SELECT count(*) AS n FROM subscription_revisions').getSingle()).read<int>('n'),
      0,
    );
    expect(
      (await database.customSelect('SELECT count(*) AS n FROM configuration_entries').getSingle()).read<int>('n'),
      0,
    );
    expect(
      (await database.customSelect('SELECT count(*) AS n FROM configuration_revision_leases').getSingle()).read<int>(
        'n',
      ),
      0,
    );
  });

  test('settings are relational scalar rows and preserve every nested core option', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp('proxyyou-sql-settings');
    addTearDown(() => directory.delete(recursive: true));
    final container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(() => CatalogTestDirectories(directory)),
        sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences)),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    await container.read(appDirectoriesProvider.future);
    final options = container.read(ConfigOptions.singboxConfigOptions).toJson();
    final export = Platform.environment['PROXYYOU_DATABASE_SETTINGS_FIXTURE'];
    final database = export == null
        ? memory()
        : ConfigurationCatalog.forTesting(
            NativeDatabase(
              File(export),
              setup: (database) => database.execute(File('native/database/schema.sql').readAsStringSync()),
            ),
            file: File(export),
          );
    addTearDown(database.close);
    final location = await database.saveCoreOptions(options);
    expect(Uri.parse(location).scheme, 'proxyyou-settings');
    final rows = await database.customSelect('SELECT kind,text_value FROM application_option_fields').get();
    expect(rows.length, greaterThan(50));
    expect(rows.any((row) => row.read<String>('kind') == 'json'), isFalse);
    expect(rows.any((row) => row.read<String>('text_value') == 'off'), isTrue);
  });

  test('ranking refresh handles 50000 SQL configurations while returning only the loaded page', () async {
    final database = memory();
    addTearDown(database.close);
    await database.customStatement(
      "INSERT INTO subscription_revisions VALUES('revision','profile','ready',1,0,'hash')",
    );
    await database.customStatement("INSERT INTO subscription_active VALUES('profile','revision')");
    await database.customStatement("INSERT INTO configuration_runtime VALUES('profile','revision','session',0,7)");
    await database.customStatement(
      'WITH RECURSIVE ids(id) AS (VALUES(0) UNION ALL SELECT id+1 FROM ids WHERE id<49999) '
      "INSERT INTO configuration_entries SELECT 'revision',id,'outbounds',id,printf('server-%05d',id), "
      "'socks','SOCKS',0,'hash-'||id FROM ids",
    );
    final timer = Stopwatch()..start();
    final view = await database.createView('profile', ProxiesSort.delay, connected: true);
    final openingMs = timer.elapsedMilliseconds;
    final version = await database.orderingVersion(view, ProxiesSort.delay);
    await database.customStatement("INSERT INTO configuration_status VALUES('revision',49999,'session',7,1,10,0,0)");
    expect(await database.orderingVersion(view, ProxiesSort.delay), isNot(version));
    timer.reset();
    final page = await database.refreshPage(view, ProxiesSort.delay, limit: 100, reorder: true);
    final refreshMs = timer.elapsedMilliseconds;
    expect(view.count, 50000);
    expect(page.length, 100);
    expect(page.first.tag, 'server-49999');
    expect(page.map((item) => item.tag).toSet().length, 100);
    expect((await database.customSelect('PRAGMA integrity_check').getSingle()).data.values.single, 'ok');
    await database.dropView(view);
    final rows = await database.customSelect('SELECT count(*) AS n FROM configuration_view_rows').getSingle();
    expect(rows.read<int>('n'), 0);
    // Measurement only: correctness does not depend on the test host's speed.
    // ignore: avoid_print
    print('50000 SQL configurations: opening ${openingMs}ms, reranking and reading 100 rows ${refreshMs}ms');
  });
}
