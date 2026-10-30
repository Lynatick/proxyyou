import 'dart:async';
import 'dart:convert';

import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_verification_cache.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Reuse successful balance proofs only within the same connected subscription.
final youtubeVerificationCacheProvider = Provider<YoutubeVerificationCache>((ref) {
  ref.watch(serviceRunningProvider);
  ref.watch(activeProfileProvider.select((profile) => (profile.value?.id, profile.value?.lastUpdate)));
  ref.watch(connectionNotifierProvider.select((value) => value.value?.isConnected));
  return YoutubeVerificationCache();
});

final youtubeSequentialVerificationProvider = Provider<bool>((ref) => PlatformUtils.isMacOS || PlatformUtils.isAndroid);

// Every stage belongs to the actual concrete server, including inside balance.
final availabilityRouteProvider = Provider<String?>((ref) {
  final mode = ref.watch(activeRoutingModeProvider);
  final tag = ref.watch(activeProxyNotifierProvider.select((proxy) => proxy.value?.tag));
  if (tag == null || tag.isEmpty) return null;
  return mode == 'balance' && !ref.watch(youtubeSequentialVerificationProvider) ? 'balance' : tag;
});

final youtubeVerificationResultProvider = Provider<Future<void> Function(YoutubeReport, bool)>((ref) {
  return (report, passed) async {
    if (report.ticket == null || report.configurationTag == null) return;
    final service = ref.read(hiddifyCoreServiceProvider);
    await service.core.bgClient.completeVerification(report.configurationTag!, report.ticket!, passed: passed);
    if (ref.mounted) ref.invalidate(activeProxyGroupsProvider);
  };
});

class YoutubeAvailabilityRequest {
  const YoutubeAvailabilityRequest(this.result, this.cancel);
  final Future<YoutubeReport> result;
  final Future<void> Function() cancel;
}

final youtubeAvailabilityRequestProvider = Provider<YoutubeAvailabilityRequest Function(String, bool)>((ref) {
  return (tag, sequential) {
    final client = ref.read(hiddifyCoreServiceProvider).core.bgClient;
    final call = sequential ? client.verifyAvailability(tag) : client.checkAvailability(tag);
    return YoutubeAvailabilityRequest(
      call.then((response) => decodeAvailabilityReport(response.message, expectedTag: tag, sequential: sequential)),
      call.cancel,
    );
  };
});

final youtubeReportProvider = FutureProvider<YoutubeReport?>((ref) {
  final running = ref.watch(serviceRunningProvider);
  ref.watch(activeProfileProvider.select((profile) => (profile.value?.id, profile.value?.lastUpdate)));
  final route = ref.watch(availabilityRouteProvider);
  // A status transition invalidates results even if a reconnect uses the same profile.
  ref.watch(connectionNotifierProvider.select((value) => value.value?.isConnected));
  if (!running || route == null) return null;
  final tag = ref.read(activeProxyNotifierProvider).value?.tag;
  if (tag == null || tag.isEmpty) return null;
  final sequential = ref.watch(youtubeSequentialVerificationProvider);
  if (sequential && ref.watch(activeRoutingModeProvider) == 'balance') {
    final cached = ref.watch(youtubeVerificationCacheProvider).get(tag);
    if (cached != null) return cached.report;
  }
  final request = ref.read(youtubeAvailabilityRequestProvider)(tag, sequential);
  ref.onDispose(() => unawaited(request.cancel().catchError((Object _) {})));
  final complete = ref.read(youtubeVerificationResultProvider);
  return request.result.then((report) async {
    if (!report.reachable && report.ticket != null && ref.mounted) {
      await complete(report, false);
    }
    return report;
  });
});

YoutubeReport decodeAvailabilityReport(String encoded, {required String expectedTag, bool sequential = false}) {
  final data = jsonDecode(encoded) as Map<String, dynamic>;
  if (data['tag'] != expectedTag) throw const FormatException('Availability server mismatch');
  final checks = (data['checks'] as List).cast<Map<String, dynamic>>();
  final pingData = data['ping'];
  if (sequential) {
    if (pingData is! Map<String, dynamic> ||
        checks.length > 2 ||
        (pingData['outcome'] == 'reachable' && checks.isEmpty) ||
        (pingData['outcome'] != 'reachable' && checks.isNotEmpty) ||
        (checks.length == 1 && checks.first['outcome'] == 'reachable') ||
        (checks.length == 2 && checks.first['outcome'] != 'reachable')) {
      throw const FormatException('Incomplete sequential availability report');
    }
  } else if (checks.length != 2) {
    throw const FormatException('Incomplete availability report');
  }
  if (checks.isNotEmpty && checks.first['is_thumbnail'] != false ||
      checks.length == 2 && checks.last['is_thumbnail'] != true) {
    throw const FormatException('Availability stages out of order');
  }
  return YoutubeReport(
    [
      for (final check in checks)
        ProbeResult(
          label: check['label'] as String,
          outcome: ProbeOutcome.values.byName(check['outcome'] as String),
          elapsed: Duration(milliseconds: (check['elapsed_ms'] as num).toInt()),
          statusCode: (check['status_code'] as num?)?.toInt(),
          tlsReason: check['tls_reason'] == null ? null : TlsFailureReason.values.byName(check['tls_reason'] as String),
          isThumbnail: check['is_thumbnail'] as bool,
        ),
    ],
    configurationTag: expectedTag,
    ticket: data['ticket'] as String?,
    ping: pingData is Map<String, dynamic>
        ? ProbeResult(
            label: 'Пинг',
            outcome: ProbeOutcome.values.byName(pingData['outcome'] as String),
            elapsed: Duration(milliseconds: (pingData['elapsed_ms'] as num).toInt()),
          )
        : null,
    interval: data['interval_ms'] is num ? Duration(milliseconds: (data['interval_ms'] as num).toInt()) : null,
  );
}
