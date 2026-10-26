import 'dart:async';

import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/configuration_catalog.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class CatalogOverviewState {
  const CatalogOverviewState(this.view, this.items, {this.loadingMore = false, this.selected});
  final CatalogView view;
  final List<OutboundInfo> items;
  final bool loadingMore;
  final String? selected;
  bool get hasMore => items.length < view.count;
}

final catalogOverviewProvider = AsyncNotifierProvider.autoDispose<CatalogOverviewNotifier, CatalogOverviewState>(
  CatalogOverviewNotifier.new,
);

class CatalogOverviewNotifier extends AsyncNotifier<CatalogOverviewState> {
  Timer? _timer;
  bool _refreshing = false;
  int _generation = 0;

  @override
  Future<CatalogOverviewState> build() async {
    final generation = ++_generation;
    final connected = ref.watch(serviceRunningProvider);
    final sort = ref.watch(proxiesSortNotifierProvider);
    final profile = await ref.watch(activeProfileProvider.future);
    if (profile == null) return const CatalogOverviewState(CatalogView('', '', 0), []);
    final database = ref.watch(configurationCatalogProvider);
    final view = await database.createView(profile.id, sort, connected: connected);
    if (!ref.mounted || generation != _generation) {
      await database.dropView(view);
      return const CatalogOverviewState(CatalogView('', '', 0), []);
    }
    ref.onDispose(() {
      _timer?.cancel();
      unawaited(database.dropView(view).catchError((Object _) {}));
    });
    final items = await database.page(view, offset: 0);
    if (ref.mounted && generation == _generation) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(refreshStatus()));
    }
    return CatalogOverviewState(view, items, selected: await database.selectedTag(profile.id));
  }

  Future<void> loadMore() async {
    final previous = state.value;
    if (previous == null || previous.loadingMore || !previous.hasMore) return;
    final generation = _generation;
    state = AsyncData(
      CatalogOverviewState(previous.view, previous.items, loadingMore: true, selected: previous.selected),
    );
    try {
      final next = await ref.read(configurationCatalogProvider).page(previous.view, offset: previous.items.length);
      if (!ref.mounted || generation != _generation) return;
      final latest = state.value ?? previous;
      state = AsyncData(CatalogOverviewState(previous.view, [...latest.items, ...next], selected: latest.selected));
    } catch (error, stack) {
      if (ref.mounted && generation == _generation) state = AsyncError(error, stack);
    }
  }

  Future<void> refreshStatus() async {
    final previous = state.value;
    if (previous == null || previous.loadingMore || _refreshing) return;
    _refreshing = true;
    final generation = _generation;
    try {
      final database = ref.read(configurationCatalogProvider);
      final revision = await database.currentRevision(
        previous.view.profile,
        connected: ref.read(serviceRunningProvider),
      );
      if (!ref.mounted || generation != _generation) return;
      if (revision != previous.view.revision) {
        ref.invalidateSelf();
        return;
      }
      final items = await database.page(previous.view, offset: 0, limit: previous.items.length);
      if (ref.mounted && generation == _generation && !(state.value?.loadingMore ?? false)) {
        state = AsyncData(CatalogOverviewState(previous.view, items, selected: previous.selected));
      }
    } catch (_) {
      // Keep the last page through a transient database lock. A later tick
      // retries; an unawaited timer must not report an uncaught exception.
    } finally {
      _refreshing = false;
    }
  }

  Future<void> selectOffline(String tag) async {
    final previous = state.value;
    if (previous == null) return;
    await ref.read(configurationCatalogProvider).selectConfiguration(previous.view, tag);
    if (!ref.mounted) return;
    final latest = state.value;
    if (latest?.view.id == previous.view.id) {
      state = AsyncData(CatalogOverviewState(previous.view, latest!.items, selected: tag));
    }
  }
}

final catalogSelectedTagProvider = Provider<String?>((ref) {
  final groups = ref.watch(activeProxyGroupsProvider).value ?? const <OutboundGroup>[];
  return groups.where((group) => group.tag == 'select').firstOrNull?.selected;
});
