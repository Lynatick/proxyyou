import 'dart:async';
import 'dart:isolate';

import 'package:dartx/dartx.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'proxies_overview_notifier.g.dart';

enum ProxiesSort {
  unsorted,
  name,
  delay,
  usage;

  String present(TranslationsEn t) => switch (this) {
    ProxiesSort.unsorted => t.pages.proxies.sortOptions.unsorted,
    ProxiesSort.name => t.pages.proxies.sortOptions.name,
    ProxiesSort.delay => t.pages.proxies.sortOptions.delay,
    ProxiesSort.usage => t.pages.proxies.sortOptions.usage,
  };
}

@Riverpod(keepAlive: true)
class ProxiesSortNotifier extends _$ProxiesSortNotifier with AppLogger {
  late final _pref = PreferencesEntry(
    preferences: ref.watch(sharedPreferencesProvider).requireValue,
    key: "proxies_sort_mode",
    defaultValue: ProxiesSort.delay,
    mapFrom: ProxiesSort.values.byName,
    mapTo: (value) => value.name,
  );

  @override
  ProxiesSort build() {
    final sortBy = _pref.read();
    loggy.info("sort proxies by: [${sortBy.name}]");
    return sortBy;
  }

  Future<void> update(ProxiesSort value) {
    state = value;
    return _pref.write(value);
  }
}

@riverpod
class ProxiesOverviewNotifier extends _$ProxiesOverviewNotifier with AppLogger {
  @override
  Stream<OutboundGroup?> build() {
    ref.disposeDelay(const Duration(seconds: 15));
    final serviceRunning = ref.watch(serviceRunningProvider);
    if (!serviceRunning) {
      return Stream.error(const ServiceNotRunning());
    }
    return ref.watch(proxyRepositoryProvider).watchActiveProxies().map((event) {
      final groups = event.getOrElse((err) => throw err);
      return groups.where((group) => group.tag == 'select').firstOrNull;
    });
  }

  Future<void> changeProxy(String groupTag, String outboundTag) async {
    loggy.debug("changing proxy, group: [$groupTag] - outbound: [$outboundTag]");
    final repository = ref.read(proxyRepositoryProvider);
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await repository.selectProxy(groupTag, outboundTag).getOrElse((err) {
      loggy.warning("error selecting outbound", err);
      throw err;
    }).run();
    // The user may have left the list or disconnected while the RPC ran.
    if (!ref.mounted) return;
    final outbounds = state.value;
    if (outbounds == null || outbounds.tag != groupTag) return;
    final newselected = outbounds.items.where((e) => e.tag == outboundTag).firstOrNull;
    if (newselected != null) {
      state = AsyncValue.data(
        OutboundGroup(
          tag: outbounds.tag,
          type: outbounds.type,
          selected: newselected.tag,
          selectable: outbounds.selectable,
          isExpand: outbounds.isExpand,
          items: outbounds.items,
        ),
      );
    }
  }

  Future<void> urlTest(String groupTag) async {
    loggy.debug("testing group: [$groupTag]");
    final repository = ref.read(proxyRepositoryProvider);
    await ref.read(hapticServiceProvider.notifier).lightImpact();
    await repository.urlTest(groupTag).getOrElse((err) {
      loggy.error("error testing group", err);
      throw err;
    }).run();
  }
}

// Pure arguments avoid capturing the notifier, Ref, or native handles.
Future<OutboundGroup?> sortOutboundGroup(OutboundGroup? group, ProxiesSort mode) async {
  if (group == null || mode == ProxiesSort.unsorted) return group;
  return Isolate.run(() {
    final items = group.items.toList();
    items.sort((a, b) {
      if (a.isGroup != b.isGroup) return a.isGroup ? -1 : 1;
      final order = switch (mode) {
        ProxiesSort.name => a.tag.compareTo(b.tag),
        ProxiesSort.delay => (a.urlTestDelay == 0 ? 0x7fffffff : a.urlTestDelay).compareTo(
          b.urlTestDelay == 0 ? 0x7fffffff : b.urlTestDelay,
        ),
        ProxiesSort.usage => (b.upload + b.download).compareTo(a.upload + a.download),
        ProxiesSort.unsorted => 0,
      };
      return order != 0 ? order : a.tag.compareTo(b.tag);
    });
    return OutboundGroup(
      tag: group.tag,
      type: group.type,
      selected: group.selected,
      selectable: group.selectable,
      isExpand: group.isExpand,
      items: items,
    );
  });
}
