import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:hiddify/core/db/converters/duration_converter.dart';
import 'package:hiddify/core/db/db.steps.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/features/app_based_routing/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/custom_loggers.dart';

part 'db.g.dart';

@DriftDatabase(tables: [ProfileEntries, AppProxyEntries, ProfileHeaders])
class Db extends _$Db with InfraLogger {
  Db([QueryExecutor? executor]) : super(executor ?? _openConnection());

  // Changing the schema? Bump `schemaVersion`, add a matching `stepByStep` step
  // below, and regenerate — full checklist in `README.md` next to this file.
  // Migrations run on every user's device on update; a wrong one can lose data.
  @override
  int get schemaVersion => 8;

  static QueryExecutor _openConnection() {
    return LazyDatabase(
      () => driftDatabase(
        name: "proxyyou_db",
        native: const DriftNativeOptions(databaseDirectory: AppDirectories.getDatabaseDirectory),
        web: DriftWebOptions(sqlite3Wasm: Uri.parse('sqlite3.wasm'), driftWorker: Uri.parse('drift_worker.js')),
      ),
    );
  }

  @override
  MigrationStrategy get migration {
    return MigrationStrategy(
      onCreate: (Migrator m) async {
        await m.createAll();
      },
      onUpgrade: stepByStep(
        from1To2: (m, schema) async {
          await m.alterTable(
            TableMigration(
              schema.profileEntries,
              columnTransformer: {schema.profileEntries.type: const Constant<String>("remote")},
              newColumns: [schema.profileEntries.type],
            ),
          );
        },
        from2To3: (m, schema) async {
          await m.createTable(schema.geoAssetEntries);
        },
        from3To4: (m, schema) async {
          final testUrlExists = await _columnExists(
            schema.profileEntries.actualTableName,
            schema.profileEntries.testUrl.name,
          );
          if (!testUrlExists) {
            await m.addColumn(schema.profileEntries, schema.profileEntries.testUrl);
          }
        },
        from4To5: (m, schema) async {
          await m.deleteTable('geo_asset_entries');
          await m.renameColumn(schema.profileEntries, 'test_url', schema.profileEntries.profileOverride);
          await m.addColumn(schema.profileEntries, schema.profileEntries.userOverride);
          await m.addColumn(schema.profileEntries, schema.profileEntries.populatedHeaders);

          await m.createTable(schema.appProxyEntries);
        },
        from5To6: (m, schema) async {
          final profileOverrideExists = await _columnExists(schema.profileEntries.actualTableName, 'profile_override');
          if (profileOverrideExists) {
            await m.dropColumn(schema.profileEntries, 'profile_override');
          }
        },
        from6To7: (m, schema) async {
          await m.addColumn(schema.profileEntries, schema.profileEntries.pinned);
        },
        from7To8: (m, schema) async {
          await m.createTable(schema.profileHeaders);
          await m.addColumn(schema.profileEntries, schema.profileEntries.overrideVersion);
          await m.addColumn(schema.profileEntries, schema.profileEntries.overrideName);
          await m.addColumn(schema.profileEntries, schema.profileEntries.overrideAutoUpdateDisable);
          await m.addColumn(schema.profileEntries, schema.profileEntries.overrideUpdateInterval);
          await m.addColumn(schema.profileEntries, schema.profileEntries.overrideExtraSecurity);
          await m.addColumn(schema.profileEntries, schema.profileEntries.overrideFragment);
          // Legacy documents are accepted only as migration input. New writes
          // keep overrides in columns and each header value in its own row.
          final profiles = await customSelect('SELECT id,user_override,populated_headers FROM profile_entries').get();
          for (final profile in profiles) {
            final id = profile.read<String>('id');
            final override = UserOverride.fromStr(profile.readNullable<String>('user_override'));
            await customStatement(
              '''
              UPDATE profile_entries SET override_version=?,override_name=?,
              override_auto_update_disable=?,override_update_interval=?,override_extra_security=?,override_fragment=?
              WHERE id=?''',
              [
                override?.version,
                override?.name,
                override?.isAutoUpdateDisable,
                override?.updateInterval,
                override?.extraSecurity,
                override?.enableFragment,
                id,
              ],
            );
            final input = profile.readNullable<String>('populated_headers');
            if (input == null) continue;
            final headers = jsonDecode(input) as Map<String, dynamic>? ?? {};
            for (final entry in headers.entries) {
              final isList = entry.value is List;
              final values = isList ? (entry.value as List).cast<Object?>() : [entry.value];
              for (var index = 0; index < (values.isEmpty ? 1 : values.length); index++) {
                await customStatement('INSERT INTO profile_headers VALUES(?,?,?,?,?)', [
                  id,
                  entry.key,
                  index,
                  isList,
                  if (values.isEmpty) null else values[index]?.toString(),
                ]);
              }
            }
          }
          await customStatement('UPDATE profile_entries SET populated_headers=NULL,user_override=NULL');
        },
      ),
    );
  }

  Future<bool> _columnExists(String table, String column) async {
    final result = await customSelect('PRAGMA table_info($table);').get();
    return result.any((row) => row.data['name'] == column);
  }
}

@DataClassName('ProfileEntry')
class ProfileEntries extends Table {
  TextColumn get id => text()();
  TextColumn get type => textEnum<ProfileType>()();
  BoolColumn get active => boolean()();
  TextColumn get name => text().withLength(min: 1)();
  TextColumn get url => text().nullable()();
  DateTimeColumn get lastUpdate => dateTime()();
  IntColumn get updateInterval => integer().nullable().map(DurationTypeConverter())();
  IntColumn get upload => integer().nullable()();
  IntColumn get download => integer().nullable()();
  IntColumn get total => integer().nullable()();
  DateTimeColumn get expire => dateTime().nullable()();
  TextColumn get webPageUrl => text().nullable()();
  TextColumn get supportUrl => text().nullable()();
  TextColumn get populatedHeaders => text().nullable()();
  TextColumn get userOverride => text().nullable()();
  IntColumn get overrideVersion => integer().nullable()();
  TextColumn get overrideName => text().nullable()();
  BoolColumn get overrideAutoUpdateDisable => boolean().nullable()();
  IntColumn get overrideUpdateInterval => integer().nullable()();
  TextColumn get overrideExtraSecurity => text().nullable()();
  BoolColumn get overrideFragment => boolean().nullable()();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('AppProxyEntry')
class AppProxyEntries extends Table {
  TextColumn get mode => textEnum<AppProxyMode>()();
  TextColumn get pkgName => text()();
  IntColumn get flags => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {mode, pkgName};
}

@DataClassName('ProfileHeader')
class ProfileHeaders extends Table {
  TextColumn get profileId => text().references(ProfileEntries, #id, onDelete: KeyAction.cascade)();
  TextColumn get name => text()();
  IntColumn get ordinal => integer()();
  BoolColumn get isList => boolean()();
  TextColumn get value => text().nullable()();
  @override
  Set<Column> get primaryKey => {profileId, name, ordinal};
}
