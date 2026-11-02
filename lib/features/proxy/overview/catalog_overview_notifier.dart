import 'dart:async';

import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/configuration_catalog.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class CatalogOverviewState {
  const CatalogOverviewState(this.view, this.items, {this.loadingMore = false, this.selected, this.offset = 0});
  final CatalogView view;
  final List<OutboundInfo> items;
  final bool loadingMore;
  final String? selected;
  final int offset;
  bool get hasMore => offset + items.length < view.count;
  OutboundInfo? itemAt(int index) => index >= offset && index < offset + items.length ? items[index - offset] : null;
}

final catalogOverviewProvider = AsyncNotifierProvider.autoDispose<CatalogOverviewNotifier, CatalogOverviewState>(
  CatalogOverviewNotifier.new,
);

class CatalogOverviewNotifier extends AsyncNotifier<CatalogOverviewState> {
  Timer? _timer;
  bool _refreshing = false;
  int _generation = 0;
  Object? _orderingVersion;
  Object? _observedOrderingVersion;
  CatalogVersion? _dataVersion;
  final _rankingClock = Stopwatch();
  int? _requestedOffset;
  int _requestedLimit = 100;
  Timer? _viewportTimer;

  @override
  Future<CatalogOverviewState> build() async {
    final generation = ++_generation;
    _orderingVersion = null;
    _observedOrderingVersion = null;
    _dataVersion = null;
    _requestedOffset = null;
    _rankingClock.reset();
    _rankingClock.start();
    final connected = ref.watch(serviceRunningProvider);
    final sort = ref.watch(proxiesSortNotifierProvider);
    final reversed = ref.watch(proxiesSortReversedProvider);
    final profile = await ref.watch(activeProfileProvider.future);
    if (profile == null) return const CatalogOverviewState(CatalogView('', '', 0), []);
    final database = ref.watch(configurationCatalogProvider);
    final view = await database.createView(profile.id, sort, connected: connected, reversed: reversed);
    if (!ref.mounted || generation != _generation) {
      await database.dropView(view);
      return const CatalogOverviewState(CatalogView('', '', 0), []);
    }
    ref.onDispose(() {
      _timer?.cancel();
      _viewportTimer?.cancel();
      unawaited(database.dropView(view).catchError((Object _) {}));
    });
    final items = await database.page(view, offset: 0);
    if (ref.mounted && generation == _generation) {
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => unawaited(refreshStatus(forceReorder: false)));
    }
    return CatalogOverviewState(view, items, selected: await database.selectedTag(profile.id));
  }

  Future<void> loadMore() async {
    final previous = state.value;
    if (previous == null || previous.loadingMore || _refreshing || !previous.hasMore) return;
    final generation = _generation;
    state = AsyncData(
      CatalogOverviewState(
        previous.view,
        previous.items,
        loadingMore: true,
        selected: previous.selected,
        offset: previous.offset,
      ),
    );
    try {
      final next = await ref
          .read(configurationCatalogProvider)
          .page(previous.view, offset: previous.offset + previous.items.length);
      if (!ref.mounted || generation != _generation) return;
      final latest = state.value ?? previous;
      final combined = [...latest.items, ...next];
      final trim = combined.length > 400 ? combined.length - 400 : 0;
      state = AsyncData(
        CatalogOverviewState(
          previous.view,
          combined.sublist(trim),
          selected: latest.selected,
          offset: latest.offset + trim,
        ),
      );
    } catch (error, stack) {
      if (ref.mounted && generation == _generation) state = AsyncError(error, stack);
    }
  }

  // A page before/after the viewport keeps scrolling and D-pad navigation smooth.
  // The cache is a window, rather than every page visited since opening the list.
  void setVisibleRange(int first, int last) {
    final current = state.value;
    if (current == null || current.view.count == 0) return;
    final offset = ((first.clamp(0, current.view.count - 1) ~/ 100) * 100 - 100).clamp(0, current.view.count);
    final end = (((last.clamp(0, current.view.count - 1) ~/ 100) + 2) * 100).clamp(0, current.view.count);
    if (_requestedOffset == offset && _requestedLimit == end - offset) return;
    _requestedOffset = offset;
    _requestedLimit = end - offset;
    _viewportTimer?.cancel();
    _viewportTimer = Timer(const Duration(milliseconds: 40), () => unawaited(refreshStatus(forceReorder: false)));
  }

  Future<void> refreshStatus({bool forceReorder = true}) async {
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
      final sort = ref.read(proxiesSortNotifierProvider);
      final version = await database.changeVersion(previous.view);
      final orderingVersion = ConfigurationCatalog.orderingKey(version, sort);
      if (!ref.mounted || generation != _generation) return;
      final dirtyOrder = orderingVersion != _orderingVersion;
      // During a stream of results, rank at most once per three seconds. A quiet
      // tick flushes the final order immediately instead of postponing forever.
      final reorder =
          dirtyOrder &&
          (forceReorder ||
              _rankingClock.elapsed >= const Duration(seconds: 3) ||
              orderingVersion == _observedOrderingVersion);
      _observedOrderingVersion = orderingVersion;
      final offset = _requestedOffset ?? previous.offset;
      final limit = _requestedOffset == null ? previous.items.length : _requestedLimit;
      if (!reorder && version == _dataVersion && offset == previous.offset && limit == previous.items.length) return;
      final items = await database.refreshPage(
        previous.view,
        sort,
        limit: limit,
        offset: offset,
        reorder: reorder,
        reversed: ref.read(proxiesSortReversedProvider),
      );
      if (ref.mounted && generation == _generation && !(state.value?.loadingMore ?? false)) {
        if (reorder) {
          _orderingVersion = orderingVersion;
          _rankingClock.reset();
        }
        _dataVersion = version;
        if (offset != previous.offset || !_sameItems(previous.items, items)) {
          state = AsyncData(
            CatalogOverviewState(previous.view, items, selected: state.value?.selected, offset: offset),
          );
        }
      }
    } catch (_) {
      // Keep the last page through a transient database lock. A later tick
      // retries; an unawaited timer must not report an uncaught exception.
    } finally {
      _refreshing = false;
      if (ref.mounted &&
          generation == _generation &&
          _requestedOffset != null &&
          state.value != null &&
          (state.value!.offset != _requestedOffset || state.value!.items.length != _requestedLimit)) {
        // A scroll that arrived during SQL work must not be lost.
        _viewportTimer?.cancel();
        _viewportTimer = Timer(const Duration(milliseconds: 100), () => unawaited(refreshStatus(forceReorder: false)));
      }
    }
  }

  Future<void> selectOffline(String tag) async {
    final previous = state.value;
    if (previous == null) return;
    await ref.read(configurationCatalogProvider).selectConfiguration(previous.view, tag);
    if (!ref.mounted) return;
    final latest = state.value;
    if (latest?.view.id == previous.view.id) {
      state = AsyncData(CatalogOverviewState(previous.view, latest!.items, selected: tag, offset: latest.offset));
    }
  }
}

bool _sameItems(List<OutboundInfo> a, List<OutboundInfo> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

final catalogSelectedTagProvider = Provider<String?>((ref) {
  final groups = ref.watch(activeProxyGroupsProvider).value ?? const <OutboundGroup>[];
  return groups.where((group) => group.tag == 'select').firstOrNull?.selected;
});
