import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'connection_lifecycle_test.dart' show NoHaptics;

class PendingSelectionRepository implements ProxyRepository {
  final selection = Completer<Unit>();
  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() => Stream.value(
    right(
      OutboundGroup(
        tag: 'select',
        selected: 'first',
        items: [
          OutboundInfo(tag: 'first'),
          OutboundInfo(tag: 'next'),
        ],
      ),
    ),
  );
  @override
  Stream<Either<ProxyFailure, List<OutboundGroup>>> watchActiveProxies() =>
      watchProxies().map((event) => event.map((group) => group == null ? <OutboundGroup>[] : [group]));
  @override
  TaskEither<ProxyFailure, Unit> selectProxy(String groupTag, String outboundTag) =>
      TaskEither(() async => right(await selection.future));
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class UnsortedProxies extends ProxiesSortNotifier {
  @override
  ProxiesSort build() => ProxiesSort.unsorted;
}

void main() {
  test('leaving the list while selecting a server does not access a disposed provider', () async {
    final repository = PendingSelectionRepository();
    final container = ProviderContainer(
      overrides: [
        serviceRunningProvider.overrideWithValue(true),
        proxyRepositoryProvider.overrideWithValue(repository),
        proxiesSortNotifierProvider.overrideWith(UnsortedProxies.new),
        hapticServiceProvider.overrideWith(NoHaptics.new),
      ],
    );
    container.listen(proxiesOverviewNotifierProvider, (_, next) {});
    await container.read(proxiesOverviewNotifierProvider.future);
    final selecting = container.read(proxiesOverviewNotifierProvider.notifier).changeProxy('select', 'next');
    await Future<void>.delayed(Duration.zero);
    container.dispose();
    repository.selection.complete(unit);
    await expectLater(selecting, completes);
  });
}
