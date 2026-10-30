import 'dart:async';
import 'dart:isolate';

import 'package:dartx/dartx.dart';
import 'package:hiddify/core/haptic/haptic_service.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/riverpod_utils.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'proxies_overview_notifier.g.dart';

final proxiesSortReversedProvider = PreferencesNotifier.create<bool, bool>('proxies_sort_reversed', false);

enum ProxiesSort {
  unsorted,
  name,
  delay,
  usage;

  String present(TranslationsEn t) => switch (this) {
    ProxiesSort.unsorted => 'По номеру',
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

  Future<void> _selectionTail = Future<void>.value();
  int _selectionGeneration = 0;

  Future<void> changeProxy(String groupTag, String outboundTag) {
    final generation = ++_selectionGeneration;
    final repository = ref.read(proxyRepositoryProvider);
    // Never let concurrent database writes acknowledge an older user choice last.
    final operation = _selectionTail.then((_) async {
      if (!ref.mounted || generation != _selectionGeneration) return;
      await ref.read(hapticServiceProvider.notifier).lightImpact();
      try {
        await repository.selectProxy(groupTag, outboundTag).getOrElse((err) => throw err).run();
      } finally {
        // A selection may already have been applied even when its RPC times out.
        // Re-read the actual route; do not leave Home/list on a stale lowest snapshot.
        if (ref.mounted) ref.invalidate(activeProxyGroupsProvider);
      }
      if (!ref.mounted || generation != _selectionGeneration) return;
      final outbounds = state.value;
      if (outbounds == null || outbounds.tag != groupTag) return;
      state = AsyncValue.data(
        OutboundGroup(
          tag: outbounds.tag,
          type: outbounds.type,
          selected: outboundTag,
          selectable: outbounds.selectable,
          isExpand: outbounds.isExpand,
          items: outbounds.items,
        ),
      );
    });
    // A failed attempt must not poison the queue for the next selection.
    _selectionTail = operation.catchError((Object _) {});
    return operation;
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
