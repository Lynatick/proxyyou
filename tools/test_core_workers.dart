import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
import 'package:hiddify/core/db/database_uri.dart';
import 'package:hiddify/gen/hiddify_core_generated_bindings.dart';
import 'package:hiddify/hiddifycore/core_interface/responsive_core_client.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';

Future<int> freePort() async {
  final s = await ServerSocket.bind('127.0.0.1', 0);
  final p = s.port;
  await s.close();
  return p;
}

Future<void> main(List<String> arguments) async {
  final largeQueue = arguments.contains('--large-queue');
  final serverCount = largeQueue ? 12040 : 60;
  final checkedTags = <String>{};
  final appRouting = arguments.contains('--app-routing');
  final generatedGroups = appRouting || arguments.contains('--generated-groups');
  final diagnosticPort = appRouting ? await freePort() : 0;
  final library = File(
    Platform.environment['PROXYYOU_TEST_CORE'] ??
        (Platform.isWindows ? 'hiddify-core/windows-x64/hiddify-core.dll' : 'hiddify-core/bin/hiddify-core.dylib'),
  ).absolute.path;
  final base = await Directory.systemTemp.createTemp('proxyyou-worker-test-');
  final socks = await ServerSocket.bind('127.0.0.1', 0);
  final grpcPort = await freePort();
  final mixedPort = await freePort();
  var active = 0;
  var peak = 0;
  var count = 0;
  final hosts = <String>{};
  final sockets = <Socket>[];
  final twenty = Completer<void>();
  socks.listen((socket) {
    sockets.add(socket);
    active++;
    count++;
    if (active > peak) peak = active;
    if (peak == 20 && !twenty.isCompleted) twenty.complete();
    final buffer = <int>[];
    var greeting = false;
    var authenticated = !largeQueue;
    String? checkedTag;
    var command = false;
    var finished = false;
    void finish() {
      if (!finished) {
        finished = true;
        active--;
      }
    }

    socket.listen(
      (bytes) {
        buffer.addAll(bytes);
        if (!greeting && buffer.length >= 2 && buffer.length >= 2 + buffer[1]) {
          final len = 2 + buffer[1];
          buffer.removeRange(0, len);
          greeting = true;
          socket.add([5, if (largeQueue) 2 else 0]);
        }
        if (greeting && !authenticated && buffer.length >= 2) {
          final usernameLength = buffer[1];
          if (buffer.length < 3 + usernameLength) return;
          final passwordLength = buffer[2 + usernameLength];
          if (buffer.length < 3 + usernameLength + passwordLength) return;
          checkedTag = utf8.decode(buffer.sublist(2, 2 + usernameLength));
          buffer.removeRange(0, 3 + usernameLength + passwordLength);
          authenticated = true;
          socket.add([1, 0]);
        }
        if (greeting && authenticated && !command && buffer.length >= 5) {
          final type = buffer[3];
          final len = type == 3 ? 7 + buffer[4] : (type == 1 ? 10 : 22);
          if (buffer.length < len) return;
          command = true;
          if (checkedTag != null) checkedTags.add(checkedTag!);
          if (type == 3) hosts.add(utf8.decode(buffer.sublist(5, 5 + buffer[4])));
          Future<void>.delayed(Duration(milliseconds: largeQueue && count > 20 ? 1 : 300), () {
            finish();
            socket.add([5, 5, 0, 1, 0, 0, 0, 0, 0, 0]);
            socket.close();
          });
        }
      },
      onDone: finish,
      onError: (_) {
        finish();
      },
    );
  });
  final native = HiddifyCoreNativeLibrary(DynamicLibrary.open(library));
  final error = native
      .setup(
        base.path.toNativeUtf8().cast(),
        base.path.toNativeUtf8().cast(),
        base.path.toNativeUtf8().cast(),
        SetupMode.GRPC_NORMAL_INSECURE.value,
        '127.0.0.1:$grpcPort'.toNativeUtf8().cast(),
        'test'.toNativeUtf8().cast(),
        0,
        0,
      )
      .cast<Utf8>()
      .toDartString();
  if (error.isNotEmpty) throw StateError('setup');
  final channel = ClientChannel(
    '127.0.0.1',
    port: grpcPort,
    options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
  );
  final core = ResponsiveCoreClient(channel, options: CallOptions(timeout: const Duration(seconds: 20)));
  try {
    {
      final settings = await core.changeHiddifySettings(
        ChangeHiddifySettingsRequest(
          hiddifySettingsJson: jsonEncode({
            'mixed-port': mixedPort,
            'direct-port': 0,
            'redirect-port': 0,
            'tproxy-port': 0,
            'clash-api-port': 0,
            'enable-tun': false,
            'set-system-proxy': false,
            'log-level': 'error',
            'balancer-strategy': 'round-robin',
            'connection-test-url': 'https://www.youtube.com/generate_204',
            'connection-test-urls': ['https://www.youtube.com/generate_204'],
            if (appRouting)
              'proxyyou-app-routing': {
                'enabled': true,
                'mode': 'include',
                'bundles': ['/Applications/ProxyYou Test.app'],
                'diagnostic_port': diagnosticPort,
              },
          }),
        ),
      );
      if (settings.messageType != MessageType.EMPTY) throw StateError('settings rejected');
    }
    final config = jsonEncode({
      'log': {'level': 'error'},
      'inbounds': [
        {'type': 'mixed', 'tag': 'in', 'listen': '127.0.0.1', 'listen_port': mixedPort},
      ],
      'outbounds': [
        if (!generatedGroups)
          {
            'type': 'selector',
            'tag': 'select',
            'outbounds': [for (var i = 0; i < serverCount; i++) 'test-$i'],
          },
        for (var i = 0; i < serverCount; i++)
          {
            'type': 'socks',
            'tag': 'test-$i',
            'server': '127.0.0.1',
            'server_port': socks.port,
            if (largeQueue) 'username': 'test-$i',
            if (largeQueue) 'password': 'local-test',
          },
      ],
      'experimental': {
        'monitoring': {
          'urls': ['https://www.youtube.com/generate_204'],
          'interval': '10m',
          'url_test_timeout': '3s',
          'debounce_window': '100ms',
        },
      },
    });
    final database = File('${base.path}/data/configurations.db');
    final location = Uri(
      scheme: 'proxyyou-db',
      path: databaseUriPath(database.absolute.path),
      queryParameters: {'profile': 'packaged-core-test'},
    ).toString();
    final imported = await core.parseForValidation(ParseRequest(configPath: location, content: config));
    if (imported.responseCode != ResponseCode.OK) throw StateError('database import rejected');
    final header = await database.open();
    final magic = await header.read(16);
    await header.close();
    if (ascii.decode(magic) != 'SQLite format 3\x00') throw StateError('configuration catalog is not SQLite');
    final started = await core.start(
      StartRequest(
        configPath: location,
        configName: 'Local concurrency test',
        enableRawConfig: false,
        disableMemoryLimit: true,
      ),
    );
    if (started.messageType != MessageType.EMPTY) throw StateError('start ${started.messageType}');
    if (arguments.contains('--availability')) {
      final response = await core.checkAvailability('test-0');
      final report = jsonDecode(response.message) as Map<String, dynamic>;
      final checks = (report['checks'] as List).cast<Map<String, dynamic>>();
      if (report['tag'] != 'test-0' ||
          report['reachable'] != false ||
          checks.length != 2 ||
          checks.any((check) => check['outcome'] == 'reachable')) {
        throw StateError('A rejected SOCKS route was reported as available');
      }
      final groups = await core.outboundsInfo(Empty()).first;
      final checked = groups.items.expand((group) => group.items).where((item) => item.tag == 'test-0');
      if (checked.isEmpty || checked.any((item) => item.urlTestDelay != 65535)) {
        throw StateError('Availability failure did not reach the native outbound snapshot');
      }
      try {
        await core.checkAvailability('select');
        throw StateError('A group was accepted as a concrete availability route');
      } on GrpcError catch (error) {
        if (error.code != StatusCode.failedPrecondition) rethrow;
      }
      stdout.writeln(
        'PASS: compiled core availability RPC pins a server, reports errors and exports unavailable state',
      );
    }
    if (generatedGroups) {
      final snapshot = await core.outboundsInfo(Empty()).first;
      final tags = snapshot.items.map((group) => group.tag).toSet();
      if (!tags.containsAll({'select', 'balance', 'lowest'})) {
        throw StateError('Missing automatic groups in database source');
      }
      for (final selected in ['test-0', 'balance', 'test-1', 'lowest', 'test-0']) {
        final response = await core.selectOutbound(SelectOutboundRequest(groupTag: 'select', outboundTag: selected));
        if (response.code != ResponseCode.OK) throw StateError('selection failed: $selected');
      }
      stdout.writeln('PASS: SQLite import and server/balance/lowest selection in compiled core');
    }
    if (!generatedGroups) {
      if (!largeQueue) await core.urlTest(UrlTestRequest(tag: 'select'));
      await twenty.future.timeout(const Duration(seconds: 15));
      if (largeQueue) {
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (checkedTags.length < serverCount && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        if (checkedTags.length != serverCount) {
          throw StateError('Large queue dropped configurations: ${checkedTags.length}/$serverCount');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final snapshot = await core.outboundsInfo(Empty()).first;
        final entries = snapshot.items
            .firstWhere((group) => group.tag == 'select')
            .items
            .where((item) => item.tag.startsWith('test-'))
            .toList();
        if (entries.length != serverCount || entries.any((item) => item.urlTestDelay != 65535)) {
          throw StateError('Large queue did not publish every completed result');
        }
        stdout.writeln('PASS: all $serverCount unique configurations checked and completed; no 10,000-job cutoff');
      } else {
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final expectedHosts = {'www.youtube.com', if (arguments.contains('--availability')) 'i.ytimg.com'};
      if (peak != 20 || hosts.length != expectedHosts.length || !hosts.containsAll(expectedHosts)) {
        throw StateError('Unexpected concurrency or destinations: peak=$peak hosts=$hosts');
      }
      stdout.writeln('PASS: peak concurrent SOCKS connections=$peak; attempts=$count; destinations=$hosts:443');
    }
    await core.stop(Empty());
  } finally {
    await channel.shutdown();
    for (final socket in sockets) {
      socket.destroy();
    }
    await socks.close();
    native.cleanup();
  }
  exit(0);
}
