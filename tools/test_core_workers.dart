import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:grpc/grpc.dart';
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
  final appRouting = arguments.contains('--app-routing');
  final generatedGroups = appRouting || arguments.contains('--generated-groups');
  final diagnosticPort = appRouting ? await freePort() : 0;
  final library = File(
    Platform.isWindows ? 'hiddify-core/windows-x64/hiddify-core.dll' : 'hiddify-core/bin/hiddify-core.dylib',
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
          socket.add([5, 0]);
        }
        if (greeting && !command && buffer.length >= 5) {
          final type = buffer[3];
          final len = type == 3 ? 7 + buffer[4] : (type == 1 ? 10 : 22);
          if (buffer.length < len) return;
          command = true;
          if (type == 3) hosts.add(utf8.decode(buffer.sublist(5, 5 + buffer[4])));
          Future<void>.delayed(const Duration(milliseconds: 300), () {
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
    if (generatedGroups) {
      final settings = await core.changeHiddifySettings(
        ChangeHiddifySettingsRequest(
          hiddifySettingsJson: jsonEncode({
            'mixed-port': mixedPort,
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
            'outbounds': [for (var i = 0; i < 60; i++) 'test-$i'],
          },
        for (var i = 0; i < 60; i++)
          {'type': 'socks', 'tag': 'test-$i', 'server': '127.0.0.1', 'server_port': socks.port},
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
    final started = await core.start(
      StartRequest(
        configContent: config,
        configName: 'Local concurrency test',
        enableRawConfig: !generatedGroups,
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
      final files = await base
          .list(recursive: true)
          .where((file) => file.path.endsWith('current-config.json'))
          .toList();
      final generated = jsonDecode(await File(files.single.path).readAsString()) as Map<String, dynamic>;
      final automatic = (generated['outbounds'] as List)
          .cast<Map<String, dynamic>>()
          .where((out) => ['select', 'balance', 'lowest'].contains(out['tag']))
          .toList();
      if (automatic.length != 3 || automatic.any((out) => out['interrupt_exist_connections'] == true)) {
        throw StateError('Generated automatic groups interrupt client connections');
      }
      stdout.writeln('PASS: embedded native binary generates select/balance/lowest without client interruption');
      if (appRouting) {
        final inbounds = (generated['inbounds'] as List).cast<Map<String, dynamic>>();
        final mixed = inbounds.firstWhere((value) => value['listen_port'] == mixedPort)['tag'];
        final diagnostic = inbounds.firstWhere((value) => value['listen_port'] == diagnosticPort)['tag'];
        final route = generated['route'] as Map<String, dynamic>;
        final rules = (route['rules'] as List).cast<Map<String, dynamic>>();
        if (!(rules[0]['inbound'] as List).contains(mixed) ||
            (rules[0]['inbound'] as List).contains(diagnostic) ||
            rules[0]['outbound'] != 'select' ||
            rules[1]['outbound'] != 'direct §hide§') {
          throw StateError('application rules do not match actual inbound tags');
        }
        stdout.writeln(
          'PASS: generated application rules match actual proxy listener; diagnostics use separate listener',
        );
      }
    }
    if (!generatedGroups) {
      await core.urlTest(UrlTestRequest(tag: 'select'));
      await twenty.future.timeout(const Duration(seconds: 15));
      await Future<void>.delayed(const Duration(seconds: 2));
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
