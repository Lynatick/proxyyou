import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/catalog_overview_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../connection/notifier/connection_lifecycle_test.dart' show NoHaptics;

class SelectionRepository implements ProxyRepository {
  String selected = 'lowest';
  int subscriptions = 0;
  final calls = <String>[];
  Completer<void>? gate;
  bool failAfterApply = false;
  final streams = <StreamController<Either<ProxyFailure, List<OutboundGroup>>>>[];
  List<OutboundGroup> snapshot() => [
    OutboundGroup(
      tag: 'select',
      selected: selected,
      items: [
        for (final tag in ['lowest', 'balance', 'server']) OutboundInfo(tag: tag, isGroup: tag != 'server'),
      ],
    ),
  ];
  @override
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies() {
    subscriptions++;
    final stream = StreamController<Either<ProxyFailure, List<OutboundGroup>>>();
    streams.add(stream);
    stream.add(Right(snapshot()));
    return stream.stream;
  }

  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) => TaskEither(() async {
    calls.add(outboundTag);
    await gate?.future;
    selected = outboundTag;
    // Deliberately drop the native stream notification, reproducing stale lowest.
    if (failAfterApply) return Left(ProxyUnexpectedFailure(StateError('late acknowledgement')));
    return const Right(unit);
  });
  Future<void> close() async {
    for (final stream in streams) {
      await stream.close();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SelectionRepository repository;
  late ProviderContainer container;
  setUp(() async {
    repository = SelectionRepository();
    container = ProviderContainer(
      overrides: [
        proxyRepositoryProvider.overrideWithValue(repository),
        serviceRunningProvider.overrideWithValue(true),
        hapticServiceProvider.overrideWith(NoHaptics.new),
      ],
    );
    container.listen(proxiesOverviewNotifierProvider, (_, _) {});
    container.listen(catalogSelectedTagProvider, (_, _) {});
    await container.read(proxiesOverviewNotifierProvider.future);
    await container.read(activeProxyGroupsProvider.future);
  });
  tearDown(() async {
    container.dispose();
    await repository.close();
  });

  test('lowest to server and balance refreshes a stale native stream and Home/list selection', () async {
    final notifier = container.read(proxiesOverviewNotifierProvider.notifier);
    for (final tag in ['server', 'lowest', 'balance', 'lowest', 'server']) {
      await notifier.changeProxy('select', tag);
      await container.pump();
      await container.read(activeProxyGroupsProvider.future);
      expect(container.read(catalogSelectedTagProvider), tag);
    }
    expect(repository.subscriptions, greaterThan(2));
  });

  test('a timed out acknowledgement still refreshes the actual selection', () async {
    repository.failAfterApply = true;
    await expectLater(
      container.read(proxiesOverviewNotifierProvider.notifier).changeProxy('select', 'balance'),
      throwsA(isA<ProxyFailure>()),
    );
    await container.pump();
    await container.read(activeProxyGroupsProvider.future);
    expect(container.read(catalogSelectedTagProvider), 'balance');
  });

  test('rapid choices serialize requests and keep the last choice after lowest', () async {
    repository.gate = Completer<void>();
    final notifier = container.read(proxiesOverviewNotifierProvider.notifier);
    final first = notifier.changeProxy('select', 'lowest');
    await Future<void>.delayed(Duration.zero);
    final second = notifier.changeProxy('select', 'server');
    final third = notifier.changeProxy('select', 'balance');
    repository.gate!.complete();
    await Future.wait([first, second, third]);
    await container.pump();
    await container.read(activeProxyGroupsProvider.future);
    expect(repository.calls, ['lowest', 'balance']);
    expect(container.read(catalogSelectedTagProvider), 'balance');
  });
}
