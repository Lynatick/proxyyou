import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grpc/grpc.dart' hide Response;
import 'package:hiddify/hiddifycore/core_interface/responsive_core_client.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcommon/common.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore_service.pbgrpc.dart';

class ControlService extends CoreServiceBase {
  ControlService({required this.keepStatusOpen});

  final bool keepStatusOpen;
  final commands = <String>[];
  @override
  Future<CoreInfoResponse> start(ServiceCall call, StartRequest request) async {
    commands.add('start');
    return CoreInfoResponse(coreState: CoreStates.STARTED);
  }

  @override
  Future<CoreInfoResponse> stop(ServiceCall call, Empty request) async {
    commands.add('stop');
    return CoreInfoResponse(coreState: CoreStates.STOPPED);
  }

  @override
  Future<CoreInfoResponse> changeHiddifySettings(ServiceCall call, ChangeHiddifySettingsRequest request) async {
    commands.add('settings');
    return CoreInfoResponse();
  }

  @override
  Stream<CoreInfoResponse> coreInfoListener(ServiceCall call, Empty request) => Stream.multi((controller) {
    controller.add(CoreInfoResponse(coreState: CoreStates.STOPPED));
    if (!keepStatusOpen) controller.close();
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class AvailabilityService extends Service {
  AvailabilityService() {
    $addMethod(
      ServiceMethod<UrlTestRequest, Response>(
        'Check',
        check,
        false,
        false,
        UrlTestRequest.fromBuffer,
        (response) => response.writeToBuffer(),
      ),
    );
  }
  final entered = Completer<void>();
  final finished = Completer<void>();
  String? tag;
  @override
  String get $name => 'proxyyou.Availability';

  Future<Response> check(ServiceCall call, Future<UrlTestRequest> request) async {
    tag = (await request).tag;
    entered.complete();
    await finished.future;
    return Response(message: 'checked');
  }
}

void main() {
  test('availability pins a tag through the control channel and does not block Stop', () async {
    final core = ControlService(keepStatusOpen: false);
    final availability = AvailabilityService();
    final server = Server.create(services: [core, availability]);
    await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final unusedPort = unused.port;
    await unused.close();
    ClientChannel channel(int port) => ClientChannel(
      '127.0.0.1',
      port: port,
      options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
    );
    final data = channel(unusedPort);
    final control = channel(server.port!);
    addTearDown(() async {
      if (!availability.finished.isCompleted) availability.finished.complete();
      await data.terminate();
      await control.terminate();
      await server.shutdown();
    });
    final client = ResponsiveCoreClient(data, controlChannel: control);
    final probe = client.checkAvailability('server-a');
    final canceled = expectLater(probe, throwsA(isA<GrpcError>()));
    await availability.entered.future.timeout(const Duration(seconds: 2));
    expect(availability.tag, 'server-a');
    expect(
      (await client.stop(Empty(), options: CallOptions(timeout: const Duration(seconds: 2)))).coreState,
      CoreStates.STOPPED,
    );
    await probe.cancel();
    await canceled;
    availability.finished.complete();
  });
  for (final keepStatusOpen in [false, true]) {
    test('control commands survive an unavailable data channel; live status=$keepStatusOpen', () async {
      final service = ControlService(keepStatusOpen: keepStatusOpen);
      final server = Server.create(services: [service]);
      await server.serve(address: InternetAddress.loopbackIPv4, port: 0);
      final unavailable = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final unusedPort = unavailable.port;
      await unavailable.close();
      ClientChannel channel(int port) => ClientChannel(
        '127.0.0.1',
        port: port,
        options: const ChannelOptions(credentials: ChannelCredentials.insecure()),
      );
      final data = channel(unusedPort);
      final control = channel(server.port!);
      addTearDown(() async {
        await data.terminate();
        await control.terminate();
        await server.shutdown();
      });
      final client = ResponsiveCoreClient(data, controlChannel: control);
      final deadline = CallOptions(timeout: const Duration(seconds: 2));
      await expectLater(client.rawOutbounds().first, throwsA(isA<GrpcError>()));
      for (var cycle = 0; cycle < 3; cycle++) {
        await client.changeHiddifySettings(ChangeHiddifySettingsRequest(), options: deadline);
        expect((await client.start(StartRequest(), options: deadline)).coreState, CoreStates.STARTED);
        expect((await client.stop(Empty(), options: deadline)).coreState, CoreStates.STOPPED);
        final status = client.coreInfoListener(Empty(), options: deadline);
        // Drain a finite test reply, including trailers, before the next command.
        // Also exercise cancellation of the live stream used by the native core.
        expect((await (keepStatusOpen ? status.first : status.single)).coreState, CoreStates.STOPPED);
      }
      expect(service.commands, List.generate(3, (_) => ['settings', 'start', 'stop']).expand((e) => e));
    });
  }
}
