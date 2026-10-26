// dart format width=80
// ignore_for_file: unused_local_variable, unused_import
import 'package:drift/drift.dart' hide isNull;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';

import 'generated/schema.dart';
import 'generated/schema_v1.dart' as v1;
import 'generated/schema_v2.dart' as v2;
import 'generated/schema_v3.dart' as v3;
import 'generated/schema_v4.dart' as v4;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SchemaVerifier verifier;

  setUpAll(() {
    verifier = SchemaVerifier(GeneratedHelper());
  });

  group('simple database migrations', () {
    // These simple tests verify all possible schema updates with a simple (no
    // data) migration. This is a quick way to ensure that written database
    // migrations properly alter the schema.
    const versions = GeneratedHelper.versions;
    for (final (i, fromVersion) in versions.indexed) {
      group('from $fromVersion', () {
        for (final toVersion in versions.skip(i + 1)) {
          test('to $toVersion', () async {
            final schema = await verifier.schemaAt(fromVersion);
            final db = Db(schema.newConnection());
            await verifier.migrateAndValidate(db, toVersion);
            await db.close();
          });
        }
      });
    }
  });

  // The following template shows how to write tests ensuring your migrations
  // preserve existing data.
  // Testing this can be useful for migrations that change existing columns
  // (e.g. by alterating their type or constraints). Migrations that only add
  // tables or columns typically don't need these advanced tests. For more
  // information, see https://drift.simonbinder.eu/migrations/tests/#verifying-data-integrity
  // TODO: This generated template shows how these tests could be written. Adopt
  // it to your own needs when testing migrations with data integrity.
  test('migration from v1 to v2 does not corrupt data', () async {
    // Add data to insert into the old database, and the expected rows after the
    // migration.
    // TODO: Fill these lists
    final oldProfileEntriesData = <v1.ProfileEntriesData>[];
    final expectedNewProfileEntriesData = <v2.ProfileEntriesData>[];

    await verifier.testWithDataIntegrity(
      oldVersion: 1,
      newVersion: 2,
      createOld: v1.DatabaseAtV1.new,
      createNew: v2.DatabaseAtV2.new,
      openTestedDatabase: Db.new,
      createItems: (batch, oldDb) {
        batch.insertAll(oldDb.profileEntries, oldProfileEntriesData);
      },
      validateItems: (newDb) async {
        expect(
          expectedNewProfileEntriesData,
          await newDb.select(newDb.profileEntries).get(),
        );
      },
    );
  });

  test('v7 migration preserves subscription headers and explicit override choices as rows', () async {
    final schema = await verifier.schemaAt(7);
    addTearDown(() => schema.rawDatabase.close());
    schema.rawDatabase.execute("""
      INSERT INTO profile_entries(id,type,active,name,url,last_update,populated_headers,user_override,pinned)
      VALUES('profile','remote',1,'Subscription','https://example.invalid/subscription','2026-10-26T12:00:00Z',
      '{"etag":["first","second"],"extra-security":"warp","empty":[]}',
      '{"version":1,"isAutoUpdateDisable":false,"enableWarp":true,"enableFragment":true,"name":"Custom"}',1)
    """);
    final database = Db(schema.newConnection());
    await verifier.migrateAndValidate(database, 8);
    final entry = await ProfileDao(database).getById('profile');
    expect(entry?.pinned, isTrue);
    expect(entry?.populatedHeaders, {
      'etag': ['first', 'second'],
      'extra-security': 'warp',
      'empty': <String>[],
    });
    expect(entry?.userOverride?.extraSecurity, 'warp');
    expect(entry?.userOverride?.isAutoUpdateDisable, isFalse);
    expect(entry?.userOverride?.enableFragment, isTrue);
    expect(entry?.userOverride?.name, 'Custom');
    final row = await database.select(database.profileEntries).getSingle();
    expect(row.userOverride, isNull);
    expect(row.populatedHeaders, isNull);
    await database.close();
  });

  group('_columnExists-backed migrations', () {
    test('migration from v3 to v4 adds test_url when missing', () async {
      final schema = await verifier.schemaAt(3);
      addTearDown(() => schema.rawDatabase.close());

      final oldDb = v3.DatabaseAtV3(schema.newConnection());
      final oldColumns = await oldDb
          .customSelect('PRAGMA table_info(profile_entries);')
          .get();

      expect(
        oldColumns.where((row) => row.data['name'] == 'test_url'),
        isEmpty,
      );
      await oldDb.close();

      final migratedDb = Db(schema.newConnection());
      await verifier.migrateAndValidate(migratedDb, 4);
      await migratedDb.close();

      final newDb = v4.DatabaseAtV4(schema.newConnection());
      final newColumns = await newDb
          .customSelect('PRAGMA table_info(profile_entries);')
          .get();
      expect(
        newColumns.where((row) => row.data['name'] == 'test_url'),
        hasLength(1),
      );
      await newDb.close();
    });

    test(
      'migration from v3 to v4 skips adding test_url when it already exists',
      () async {
        final schema = await verifier.schemaAt(3);
        addTearDown(() => schema.rawDatabase.close());

        schema.rawDatabase.execute(
          'ALTER TABLE profile_entries ADD COLUMN test_url TEXT NULL;',
        );

        final migratedDb = Db(schema.newConnection());
        await verifier.migrateAndValidate(migratedDb, 4);
        await migratedDb.close();

        final newDb = v4.DatabaseAtV4(schema.newConnection());
        final newColumns = await newDb
            .customSelect('PRAGMA table_info(profile_entries);')
            .get();
        expect(
          newColumns.where((row) => row.data['name'] == 'test_url'),
          hasLength(1),
        );
        await newDb.close();
      },
    );
  });
}
