import 'dart:async';
import 'dart:math';

import 'package:fluentui_system_icons/fluentui_system_icons.dart';
import 'package:flutter/material.dart';
import 'package:gap/gap.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/overview/catalog_overview_notifier.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ProxiesOverviewPage extends HookConsumerWidget with PresLogger {
  const ProxiesOverviewPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(translationsProvider).requireValue;
    final catalog = ref.watch(catalogOverviewProvider);
    final sortBy = ref.watch(proxiesSortNotifierProvider);
    final connected = ref.watch(serviceRunningProvider);
    final selected = ref.watch(catalogSelectedTagProvider);
    ref.watch(proxiesOverviewNotifierProvider);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.pages.proxies.title),
        actions: [
          IconButton(
            tooltip: 'Обновить порядок списка',
            onPressed: () => ref.invalidate(catalogOverviewProvider),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<ProxiesSort>(
            initialValue: sortBy,
            onSelected: ref.read(proxiesSortNotifierProvider.notifier).update,
            icon: const Icon(FluentIcons.arrow_sort_24_regular),
            tooltip: t.pages.proxies.sort,
            itemBuilder: (context) => [
              ...ProxiesSort.values.map((value) => PopupMenuItem(value: value, child: Text(value.present(t)))),
            ],
          ),
          const Gap(8),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: connected ? () => ref.read(proxiesOverviewNotifierProvider.notifier).urlTest('select') : null,
        tooltip: t.pages.proxies.testDelay,
        child: const Icon(FluentIcons.flash_24_filled),
      ),
      body: catalog.when(
        data: (data) {
          if (data.view.count == 0) return Center(child: Text(t.pages.proxies.empty));
          final modes = data.view.count > 1
              ? [
                  OutboundInfo(tag: 'balance', tagDisplay: 'balance', type: 'balancer', isGroup: true),
                  OutboundInfo(tag: 'lowest', tagDisplay: 'lowest', type: 'balancer', isGroup: true),
                ]
              : const <OutboundInfo>[];
          final indices = <String, int>{
            for (var index = 0; index < modes.length; index++) modes[index].tag: index,
            for (var index = 0; index < data.items.length; index++) data.items[index].tag: modes.length + index,
          };
          return LayoutBuilder(
            builder: (context, constraints) {
              final columns = PlatformUtils.isMobile && constraints.maxWidth < 600
                  ? 1
                  : max(1, (constraints.maxWidth / 268).floor());
              return GridView.builder(
                padding: const EdgeInsets.only(bottom: 86),
                itemCount: modes.length + data.items.length + (data.hasMore ? 1 : 0),
                findChildIndexCallback: (key) => key is ValueKey<String> ? indices[key.value] : null,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: columns, mainAxisExtent: 72),
                itemBuilder: (context, index) {
                  if (index == modes.length + data.items.length) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) unawaited(ref.read(catalogOverviewProvider.notifier).loadMore());
                    });
                    return const Center(child: CircularProgressIndicator());
                  }
                  final proxy = index < modes.length ? modes[index] : data.items[index - modes.length];
                  return ProxyTile(
                    proxy,
                    key: ValueKey(proxy.tag),
                    selected: (connected ? selected : data.selected) == proxy.tag,
                    onTap: () async {
                      if (!connected) {
                        await ref.read(catalogOverviewProvider.notifier).selectOffline(proxy.tag);
                        return;
                      }
                      await ref.read(proxiesOverviewNotifierProvider.notifier).changeProxy('select', proxy.tag);
                    },
                  );
                },
              );
            },
          );
        },
        error: (error, stackTrace) => Center(child: Text(t.presentShortError(error))),
        loading: () => const Center(child: CircularProgressIndicator()),
      ),
    );
  }
}
