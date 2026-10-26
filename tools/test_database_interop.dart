import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/db/database_uri.dart';
import 'package:hiddify/core/db/relational_value_codec.dart';
import 'package:hiddify/gen/hiddify_core_generated_bindings.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';
import 'package:sqlite3/sqlite3.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('proxyyou-sqlite-interop-');
  final reservation = await ServerSocket.bind('127.0.0.1', 0);
  final port = reservation.port;
  await reservation.close();
  final native = HiddifyCoreNativeLibrary(DynamicLibrary.open(Platform.environment['PROXYYOU_TEST_CORE']!));
  final error = native
      .setup(
        directory.path.toNativeUtf8().cast(),
        directory.path.toNativeUtf8().cast(),
        directory.path.toNativeUtf8().cast(),
        SetupMode.GRPC_NORMAL_INSECURE.value,
        '127.0.0.1:$port'.toNativeUtf8().cast(),
        ''.toNativeUtf8().cast(),
        0,
        0,
      )
      .cast<Utf8>()
      .toDartString();
  if (error.isNotEmpty) throw StateError(error);
  final channel = ClientChannel(
    '127.0.0.1',
    port: port,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  final core = CoreClient(channel, options: CallOptions(timeout: const Duration(seconds: 10)));
  final file = File('${directory.path}/data/configurations.db');
  final database = sqlite3.open(file.path);
  try {
    for (var index = 0; index < 20; index++) {
      final version = 'dart-options-$index';
      final fields = encodeRelationalValues({
        'log-level': 'off',
        'mixed-port': 0,
        'direct-port': 0,
        'redirect-port': 0,
        'tproxy-port': 0,
        'clash-api-port': 0,
        'enable-tun': false,
        'set-system-proxy': false,
      });
      database.execute('BEGIN IMMEDIATE');
      database.execute("INSERT INTO application_options VALUES(?,'ready','semantic',?)", [version, index]);
      for (final field in fields) {
        database.execute('INSERT INTO application_option_fields VALUES(?,?,?,?,?,?,?,?)', field.values(version));
      }
      database.execute('COMMIT');
      if (database.select('SELECT id FROM application_options WHERE id=?', [version]).isEmpty) {
        throw StateError('Dart did not commit $version');
      }
      final location = Uri(
        scheme: 'proxyyou-settings',
        path: databaseUriPath(file.path),
        queryParameters: {'revision': version},
      ).toString();
      await core.changeHiddifySettings(ChangeHiddifySettingsRequest(hiddifySettingsJson: location));
      stdout.writeln('Verified Dart → core settings revision $index');
    }
    if (database.select('SELECT count(*) AS total FROM application_options').single['total'] != 20) {
      throw StateError('A settings revision was lost');
    }
    if (database.select('PRAGMA integrity_check').single.values.single != 'ok') {
      throw StateError('SQLite integrity check failed');
    }
    stdout.writeln('PASS: twenty settings commits remain visible across Dart and native SQLite connections');
  } finally {
    database.close();
    await channel.shutdown();
    native.cleanup();
  }
}
