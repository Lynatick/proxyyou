import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fixnum/fixnum.dart';
import 'package:hiddify/core/db/database_uri.dart';
import 'package:hiddify/core/db/relational_value_codec.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:uuid/uuid.dart';

// The native core owns schema creation and revisions. Drift uses a persistent
// worker isolate; this connection only reads main tables and writes TEMP views.
class ConfigurationCatalog extends GeneratedDatabase {
  ConfigurationCatalog(File file)
    : databaseFile = file,
      super(
        NativeDatabase.createInBackground(
          file,
          enableMigrations: false,
          setup: (database) {
            database.execute('PRAGMA foreign_keys=ON');
            database.execute('PRAGMA busy_timeout=5000');
          },
        ),
      );

  ConfigurationCatalog.forTesting(super.executor, {File? file}) : databaseFile = file ?? File('test-catalog.db');
  final File databaseFile;

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];

  Future<String> saveCoreOptions(Map<String, dynamic> options) async {
    final version = const Uuid().v4();
    final fields = encodeRelationalValues(options);
    await transaction(() async {
      await customStatement("INSERT INTO application_options VALUES(?,'staging','semantic',?)", [
        version,
        DateTime.now().millisecondsSinceEpoch,
      ]);
      await batch((batch) {
        for (final field in fields) {
          batch.customStatement('INSERT INTO application_option_fields VALUES(?,?,?,?,?,?,?,?)', field.values(version));
        }
      });
      await customStatement("UPDATE application_options SET state='ready' WHERE id=?", [version]);
    });
    return Uri(
      scheme: 'proxyyou-settings',
      path: databaseUriPath(databaseFile.absolute.path),
      queryParameters: {'revision': version},
    ).toString();
  }

  Future<CatalogView> createView(String profile, ProxiesSort sort, {required bool connected}) async {
    final view = const Uuid().v4();
    await customStatement(
      'INSERT INTO configuration_revision_leases(token,revision,owner_pid,created) '
      'SELECT ?,CASE WHEN ?=1 THEN COALESCE(r.revision,a.revision) ELSE a.revision END,?,? '
      'FROM subscription_active a LEFT JOIN configuration_runtime r ON r.profile_id=a.profile_id '
      'WHERE a.profile_id=?',
      [view, if (connected) 1 else 0, pid, DateTime.now().millisecondsSinceEpoch, profile],
    );
    final revisionRow = await customSelect(
      'SELECT revision FROM configuration_revision_leases WHERE token=?',
      variables: [Variable(view)],
    ).getSingleOrNull();
    if (revisionRow == null) return const CatalogView('', '', 0);
    final revision = revisionRow.read<String>('revision');
    try {
      await customStatement(
        'CREATE TEMP TABLE IF NOT EXISTS configuration_view_rows( '
        'view_id TEXT NOT NULL,position INTEGER NOT NULL,revision TEXT NOT NULL,entry_id INTEGER NOT NULL, '
        'PRIMARY KEY(view_id,position)) WITHOUT ROWID',
      );
      final order = switch (sort) {
        ProxiesSort.unsorted => "CASE e.section WHEN 'outbounds' THEN 0 ELSE 1 END,e.ordinal,e.id",
        ProxiesSort.name => 'e.tag,e.id',
        ProxiesSort.delay => 'CASE WHEN $delay=0 THEN 2147483647 ELSE $delay END,e.tag,e.id',
        ProxiesSort.usage => 'COALESCE(u.upload+u.download,0) DESC,e.tag,e.id',
      };
      await customStatement(
        'INSERT INTO configuration_view_rows '
        'SELECT ?,row_number() OVER(ORDER BY $order)-1,e.revision,e.id '
        'FROM configuration_entries e $statusJoin '
        "WHERE e.revision=? AND e.is_group=0 AND e.section<>'root' "
        "AND e.type NOT IN ('direct','dns','block','custom') AND instr(e.tag,'§hide§')=0",
        [view, revision],
      );
      final count = await customSelect(
        'SELECT count(*) AS count FROM configuration_view_rows WHERE view_id=?',
        variables: [Variable(view)],
      ).getSingle();
      return CatalogView(view, revision, count.read<int>('count'), profile: profile);
    } catch (_) {
      await customStatement('DELETE FROM configuration_revision_leases WHERE token=?', [view]);
      rethrow;
    }
  }

  // Freeze ordering per view while checks run. Status values remain live, so
  // pagination never duplicates/skips a node or moves TV focus after a ping.
  Future<List<OutboundInfo>> page(CatalogView view, {required int offset, int limit = 100}) async {
    final rows = await customSelect(
      'SELECT e.tag,e.type,e.display,$delay AS delay,COALESCE(u.upload,0) AS upload,COALESCE(u.download,0) AS download '
      'FROM configuration_view_rows v JOIN configuration_entries e '
      'ON e.revision=v.revision AND e.id=v.entry_id $statusJoin '
      'WHERE v.view_id=? AND v.position>=? AND v.position<? ORDER BY v.position',
      variables: [Variable(view.id), Variable(offset), Variable(offset + limit)],
    ).get();
    return rows
        .map((row) {
          final tag = row.read<String>('tag');
          return OutboundInfo(
            tag: tag,
            tagDisplay: tag.split('§').first.trim(),
            type: row.read<String>('display').isEmpty ? row.read<String>('type') : row.read<String>('display'),
            upload: Int64(row.read<int>('upload')),
            download: Int64(row.read<int>('download')),
            isVisible: true,
            urlTestDelay: row.read<int>('delay'),
          );
        })
        .toList(growable: false);
  }

  Future<void> dropView(CatalogView view) async {
    if (view.id.isEmpty) return;
    try {
      await customStatement('DELETE FROM configuration_view_rows WHERE view_id=?', [view.id]);
    } finally {
      await customStatement('DELETE FROM configuration_revision_leases WHERE token=?', [view.id]);
    }
  }

  Future<String?> currentRevision(String profile, {required bool connected}) async => (await customSelect(
    'SELECT CASE WHEN ?=1 THEN COALESCE(r.revision,a.revision) ELSE a.revision END AS revision '
    'FROM subscription_active a LEFT JOIN configuration_runtime r ON r.profile_id=a.profile_id WHERE a.profile_id=?',
    variables: [Variable(connected ? 1 : 0), Variable(profile)],
  ).getSingleOrNull())?.read<String>('revision');

  Future<String?> selectedTag(String profile) async => (await customSelect(
    "SELECT tag FROM configuration_selections WHERE profile_id=? AND group_tag='select'",
    variables: [Variable(profile)],
  ).getSingleOrNull())?.read<String>('tag');

  Future<void> selectConfiguration(CatalogView view, String tag) async {
    final exists = tag == 'balance' || tag == 'lowest'
        ? view.count > 1
        : (await customSelect(
                'SELECT 1 FROM configuration_entries WHERE revision=? AND tag=? AND is_group=0 LIMIT 1',
                variables: [Variable(view.revision), Variable(tag)],
              ).getSingleOrNull()) !=
              null;
    if (!exists) throw StateError('Конфигурация отсутствует в подписке');
    final changed = await customUpdate(
      "INSERT INTO configuration_selections(profile_id,group_tag,tag) SELECT ?,'select',? "
      'WHERE EXISTS(SELECT 1 FROM subscription_active WHERE profile_id=?) '
      'ON CONFLICT(profile_id,group_tag) DO UPDATE SET tag=excluded.tag',
      variables: [Variable(view.profile), Variable(tag), Variable(view.profile)],
    );
    if (changed == 0) throw StateError('Подписка удалена');
  }

  static const statusJoin =
      'LEFT JOIN configuration_status s ON s.revision=e.revision AND s.entry_id=e.id '
      'LEFT JOIN configuration_runtime r ON r.revision=e.revision AND r.session=s.session '
      'LEFT JOIN configuration_usage u ON u.revision=e.revision AND u.entry_id=e.id';
  static const delay =
      'CASE WHEN r.session IS NULL OR s.network_epoch<>r.network_epoch THEN 0 '
      'WHEN s.unavailable=1 THEN 65535 ELSE COALESCE(s.delay,0) END';
}

class CatalogView {
  const CatalogView(this.id, this.revision, this.count, {this.profile = ''});
  final String id;
  final String revision;
  final int count;
  final String profile;
}

final configurationCatalogProvider = Provider<ConfigurationCatalog>((ref) {
  final catalog = ConfigurationCatalog(ref.watch(profilePathResolverProvider).database);
  ref.onDispose(catalog.close);
  return catalog;
});
