import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/db/db.dart';

import 'package:hiddify/core/utils/exception_handler.dart';
import 'package:hiddify/features/profile/data/profile_data_mapper.dart';
import 'package:hiddify/features/profile/data/profile_data_source.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/profile_path_resolver.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:uuid/uuid.dart';

abstract interface class ProfileRepository {
  TaskEither<ProfileFailure, Unit> init();
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id);
  TaskEither<ProfileFailure, Unit> setAsActive(String id);
  TaskEither<ProfileFailure, Unit> setPinned(String id, bool pinned);
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive);
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile();
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile();
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  });
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken});
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride});
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity nProfile, String nContent);
  TaskEither<ProfileFailure, Unit> validateConfig(
    String path,
    String tempPath,
    Map<String, dynamic>? profileOverride,
    bool debug,
  );
  TaskEither<ProfileFailure, String> generateConfig(String id);
  TaskEither<ProfileFailure, String> getRawConfig(String id);
}

class ProfileRepositoryImpl with ExceptionHandler, InfraLogger implements ProfileRepository {
  ProfileRepositoryImpl({
    required this._profileDataSource,
    required this._profilePathResolver,
    required this._singbox,
    required ConfigOptionRepository configOptionRepository,
    required this._profileParser,
  }) : _configOptionRepo = configOptionRepository;

  final ProfileDataSource _profileDataSource;
  final ProfilePathResolver _profilePathResolver;
  final HiddifyCoreService _singbox;
  final ConfigOptionRepository _configOptionRepo;
  final ProfileParser _profileParser;

  @override
  TaskEither<ProfileFailure, Unit> init() {
    return exceptionHandler(() async {
      if (!kIsWeb) {
        if (!await _profilePathResolver.directory.exists()) {
          await _profilePathResolver.directory.create(recursive: true);
        }
        final profiles = await _profileDataSource
            .watchAll(sort: ProfilesSort.lastUpdate, sortMode: SortMode.ascending)
            .first;
        for (final profile in profiles) {
          final legacy = _profilePathResolver.file(profile.id);
          if (!await legacy.exists()) continue;
          (await _singbox
                  .validateConfigByPath(
                    _profilePathResolver.databaseLocation(profile.id, operation: 'migrate'),
                    legacy.path,
                    false,
                  )
                  .run())
              .getOrElse((error) => throw ProfileFailure.invalidConfig(error));
          // Keep the migration input as a rollback copy; never use it at runtime.
          await legacy.rename('${legacy.path}.migrated');
        }
      }

      return right(unit);
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) {
    return TaskEither.tryCatch(
      () => _profileDataSource.getById(id).then((value) => value),
      ProfileUnexpectedFailure.new,
    );
  }

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.edit(id, const ProfileEntriesCompanion(active: Value(true)));
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> setPinned(String id, bool pinned) {
    return TaskEither.tryCatch(() async {
      await _profileDataSource.edit(id, ProfileEntriesCompanion(pinned: Value(pinned)));
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) {
    return TaskEither.tryCatch(() async {
      (await _singbox.deleteDatabaseProfile(_profilePathResolver.databaseLocation(id, operation: 'delete')).run())
          .getOrElse((error) => throw ProfileFailure.unexpected(error));
      await _profileDataSource.deleteById(id, isActive);
      return unit;
    }, ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, ProfileEntity?>> watchActiveProfile() {
    return _profileDataSource.watchActiveProfile().map((event) => event).handleExceptions((error, stackTrace) {
      loggy.error("error watching active profile", error, stackTrace);
      return ProfileUnexpectedFailure(error, stackTrace);
    });
  }

  @override
  Stream<Either<ProfileFailure, bool>> watchHasAnyProfile() {
    return _profileDataSource
        .watchProfilesCount()
        .map((event) => event != 0)
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) {
    return _profileDataSource
        .watchAll(sort: sort, sortMode: sortMode)
        .map((event) => event)
        .handleExceptions(ProfileUnexpectedFailure.new);
  }

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken}) =>
      TaskEither.tryCatch(
        () async => await _profileDataSource.getByUrl(url).then((profEntry) => profEntry),
        ProfileFailure.unexpected,
      ).flatMap((profEntity) {
        // if profile is null, generate id
        final id = profEntity?.id ?? const Uuid().v4();
        final location = _profilePathResolver.databaseLocation(id);
        final tempFile = _profilePathResolver.tempFile('$id-${const Uuid().v4()}');
        return TaskEither(() async {
          try {
            TaskEither<ProfileFailure, Unit> operation;
            if (profEntity != null && profEntity is RemoteProfileEntity) {
              // Update
              final remoteProfile = userOverride == null ? profEntity : profEntity.copyWith(userOverride: userOverride);
              operation = _profileParser
                  .updateRemote(rp: remoteProfile, tempFilePath: tempFile.path, cancelToken: cancelToken)
                  .flatMap(
                    (profEntity) =>
                        validateConfig(location, tempFile.path, profEntity.profileOverride(), false).flatMap(
                          (unit) => TaskEither.tryCatch(() async {
                            await _profileDataSource.edit(id, profEntity.toUpdateEntry(), metadata: profEntity);
                            return unit;
                          }, ProfileFailure.unexpected),
                        ),
                  );
            } else {
              // Add
              operation = _profileParser
                  .addRemote(
                    id: id,
                    url: url,
                    tempFilePath: tempFile.path,
                    userOverride: userOverride,
                    cancelToken: cancelToken,
                  )
                  .flatMap(
                    (profEntity) =>
                        validateConfig(location, tempFile.path, profEntity.profileOverride(), false).flatMap(
                          (unit) => TaskEither.tryCatch(() async {
                            await _insertProfile(profEntity);
                            return unit;
                          }, ProfileFailure.unexpected),
                        ),
                  );
            }
            return await operation.run();
          } finally {
            if (await tempFile.exists()) await tempFile.delete();
          }
        });
      });

  Future<void> _insertProfile(ProfileEntity profile) async {
    try {
      await _profileDataSource.insert(profile);
    } catch (error, stack) {
      // The native revision commits before profile metadata. If metadata
      // insertion failed, retire the otherwise invisible new catalogue.
      if (await _profileDataSource.getById(profile.id) == null) {
        await _singbox
            .deleteDatabaseProfile(_profilePathResolver.databaseLocation(profile.id, operation: 'delete'))
            .run();
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  @override
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride}) =>
      TaskEither.tryCatch(() async {
        final id = const Uuid().v4();
        final location = _profilePathResolver.databaseLocation(id);
        final tempFile = _profilePathResolver.tempFile(id);
        try {
          await writeSubscriptionContent(tempFile.path, content);
          final task = _profileParser
              .addLocal(id: id, content: content, tempFilePath: tempFile.path, userOverride: userOverride)
              .flatMap(
                (profEntity) => validateConfig(location, tempFile.path, profEntity.profileOverride(), false).flatMap(
                  (unit) => TaskEither.tryCatch(() async {
                    await _insertProfile(profEntity);
                    return unit;
                  }, ProfileFailure.unexpected),
                ),
              );
          return (await task.run()).getOrElse((l) => throw l);
        } finally {
          if (tempFile.existsSync()) tempFile.deleteSync();
        }
      }, ProfileFailure.unexpected);

  @override
  TaskEither<ProfileFailure, Unit> offlineUpdate(ProfileEntity profile, String nContent) =>
      TaskEither.tryCatch(() async {
        final entry = await _profileDataSource.getById(profile.id);
        final original = entry;
        if (original == null || original.runtimeType != profile.runtimeType) throw const ProfileFailure.notFound();
        if (nContent.isEmpty) {
          final metadata = ProfileParser.parse(
            tempFilePath: '',
            profile: profile,
            metadataOnly: true,
          ).getOrElse((error) => throw error);
          await _profileDataSource.edit(original.id, metadata.toUpdateEntry(), metadata: metadata);
          return unit;
        }
        final temporary = _profilePathResolver.tempFile(original.id);
        try {
          await writeSubscriptionContent(temporary.path, nContent);
          final parsed =
              (await _profileParser
                      .offlineUpdate(
                        profile: original.copyWith(userOverride: profile.userOverride),
                        tempFilePath: temporary.path,
                      )
                      .run())
                  .getOrElse((error) => throw error);
          (await validateConfig(
            _profilePathResolver.databaseLocation(original.id),
            temporary.path,
            parsed.profileOverride(),
            false,
          ).run()).getOrElse((error) => throw error);
          await _profileDataSource.edit(original.id, parsed.toUpdateEntry(), metadata: parsed);
          return unit;
        } finally {
          if (await temporary.exists()) await temporary.delete();
        }
      }, (error, stack) => error is ProfileFailure ? error : ProfileFailure.unexpected(error, stack));

  @override
  TaskEither<ProfileFailure, Unit> validateConfig(
    String path,
    String tempPath,
    Map<String, dynamic>? profileOverride,
    bool debug,
  ) => TaskEither.fromEither(_configOptionRepo.fullOptionsOverrided(profileOverride))
      .mapLeft((configOptionFailure) => ProfileFailure.invalidConfig(null, configOptionFailure))
      .flatMap(
        (overridedOptions) => _singbox
            .changeOptions(overridedOptions)
            .mapLeft(ProfileFailure.invalidConfig)
            .flatMap((_) => _singbox.validateConfigByPath(path, tempPath, debug).mapLeft(ProfileFailure.invalidConfig)),
      );

  @override
  TaskEither<ProfileFailure, String> generateConfig(String id) =>
      TaskEither.right(_profilePathResolver.databaseLocation(id));

  @override
  TaskEither<ProfileFailure, String> getRawConfig(String id) => TaskEither.right('');
}
