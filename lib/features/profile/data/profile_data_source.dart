import 'package:drift/drift.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/utils/utils.dart';

part 'profile_data_source.g.dart';

abstract interface class ProfileDataSource {
  Future<ProfileEntity?> getById(String id);
  Future<ProfileEntity?> getByUrl(String url);
  Future<ProfileEntity?> getByName(String name);
  Stream<ProfileEntity?> watchActiveProfile();
  Stream<int> watchProfilesCount();
  Stream<List<ProfileEntity>> watchAll({required ProfilesSort sort, required SortMode sortMode});
  Future<void> insert(ProfileEntity entity);
  Future<void> edit(String id, ProfileEntriesCompanion entry, {ProfileEntity? metadata});
  Future<void> deleteById(String id, bool isActive);
}

Map<SortMode, OrderingMode> orderMap = {SortMode.ascending: OrderingMode.asc, SortMode.descending: OrderingMode.desc};

@DriftAccessor(tables: [ProfileEntries, ProfileHeaders])
class ProfileDao extends DatabaseAccessor<Db> with _$ProfileDaoMixin, InfraLogger implements ProfileDataSource {
  ProfileDao(super.db);

  Future<List<ProfileEntity>> _entities(List<ProfileEntry> entries) async {
    if (entries.isEmpty) return [];
    final ids = entries.map((entry) => entry.id).toSet();
    final rows = await (profileHeaders.select()..orderBy([(table) => OrderingTerm.asc(table.ordinal)])).get();
    final headers = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      if (!ids.contains(row.profileId)) continue;
      final values = headers.putIfAbsent(row.profileId, () => {});
      if (row.isList) {
        final list = values.putIfAbsent(row.name, () => <String>[]) as List<String>;
        if (row.value != null) list.add(row.value!);
      } else {
        values[row.name] = row.value ?? '';
      }
    }
    return entries.map((entry) => entry.toEntity(headers: headers[entry.id])).toList();
  }

  Future<ProfileEntity?> _entity(ProfileEntry? entry) async => entry == null ? null : (await _entities([entry])).single;

  @override
  Future<ProfileEntity?> getById(String id) async =>
      _entity(await (profileEntries.select()..where((table) => table.id.equals(id))).getSingleOrNull());

  @override
  Future<ProfileEntity?> getByUrl(String url) async => _entity(
    await (profileEntries.select()
          ..where((table) => table.url.like('%$url%'))
          ..limit(1))
        .getSingleOrNull(),
  );

  @override
  Future<ProfileEntity?> getByName(String name) async => _entity(
    await (profileEntries.select()
          ..where((table) => table.name.equals(name))
          ..limit(1))
        .getSingleOrNull(),
  );

  @override
  Stream<ProfileEntity?> watchActiveProfile() =>
      (profileEntries.select()
            ..where((table) => table.active.equals(true))
            ..limit(1))
          .watchSingleOrNull()
          .asyncMap(_entity)
          .distinct();

  @override
  Stream<int> watchProfilesCount() {
    final count = profileEntries.id.count();
    return (profileEntries.selectOnly()..addColumns([count])).map((exp) => exp.read(count)!).watchSingle().distinct();
  }

  @override
  Stream<List<ProfileEntity>> watchAll({required ProfilesSort sort, required SortMode sortMode}) {
    return (profileEntries.select()..orderBy([
          (tbl) => OrderingTerm(expression: tbl.active, mode: OrderingMode.desc),
          (tbl) => OrderingTerm(expression: tbl.pinned, mode: OrderingMode.desc),
          (tbl) {
            final trafficRatio = (tbl.download + tbl.upload) / tbl.total;
            final isExpired = tbl.expire.isSmallerOrEqualValue(DateTime.now());
            return OrderingTerm(
              expression:
                  (trafficRatio.isNull() | trafficRatio.isSmallerThanValue(1)) &
                  (isExpired.isNull() | isExpired.equals(false)),
              mode: OrderingMode.desc,
            );
          },
          switch (sort) {
            ProfilesSort.name => (tbl) => OrderingTerm(expression: tbl.name, mode: orderMap[sortMode]!),
            ProfilesSort.lastUpdate => (tbl) => OrderingTerm(expression: tbl.lastUpdate, mode: orderMap[sortMode]!),
          },
        ]))
        .watch()
        .asyncMap(_entities);
  }

  @override
  Future<void> insert(ProfileEntity entity) async {
    final entry = entity.toInsertEntry();
    await transaction(() async {
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      final name = StringBuffer(entry.name.value);
      while (await getByName(name.toString()) != null) {
        name.write('${randomInt(0, 9).run()}');
      }
      await into(profileEntries).insert(entry.copyWith(name: Value(name.toString())));
      await _writeHeaders(entity);
    });
  }

  @override
  Future<void> edit(String id, ProfileEntriesCompanion entry, {ProfileEntity? metadata}) async {
    await transaction(() async {
      final profile = await (profileEntries.select()..where((tbl) => tbl.id.equals(id))).getSingleOrNull();
      if (profile == null) {
        loggy.info('profile with id : [$id] deleted');
        return;
      }
      if (entry.active.present && entry.active.value) {
        await update(profileEntries).write(const ProfileEntriesCompanion(active: Value(false)));
      }
      await (update(profileEntries)..where((tbl) => tbl.id.equals(id))).write(entry);
      if (metadata != null) await _writeHeaders(metadata);
    });
  }

  @override
  Future<void> deleteById(String id, bool isActive) async {
    await transaction(() async {
      await (delete(profileHeaders)..where((tbl) => tbl.profileId.equals(id))).go();
      await (delete(profileEntries)..where((tbl) => tbl.id.equals(id))).go();

      if (isActive) {
        final profiles = await (profileEntries.select()..where((tbl) => tbl.id.equals(id).not())).get();
        if (profiles.isEmpty) return;
        final prof = profiles.first;
        await (update(
          profileEntries,
        )..where((tbl) => tbl.id.equals(prof.id))).write(const ProfileEntriesCompanion(active: Value(true)));
      }
    });
  }

  Future<void> _writeHeaders(ProfileEntity profile) async {
    await (delete(profileHeaders)..where((table) => table.profileId.equals(profile.id))).go();
    final rows = <ProfileHeadersCompanion>[];
    for (final entry in (profile.populatedHeaders ?? <String, dynamic>{}).entries) {
      final items = entry.value is List ? (entry.value as List).cast<Object?>() : [entry.value];
      for (var index = 0; index < (items.isEmpty ? 1 : items.length); index++) {
        rows.add(
          ProfileHeadersCompanion.insert(
            profileId: profile.id,
            name: entry.key,
            ordinal: index,
            isList: entry.value is List,
            value: Value(items.isEmpty ? null : items[index]?.toString()),
          ),
        );
      }
    }
    await batch((batch) => batch.insertAll(profileHeaders, rows));
  }
}
