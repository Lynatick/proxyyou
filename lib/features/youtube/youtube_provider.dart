import 'dart:async';
import 'dart:convert';

import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/hiddifycore/hiddify_core_service_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// A balance label can change for every new browser connection. Only the route
// and session invalidate this check; the core pins both requests to one server.
final availabilityRouteProvider = Provider<String?>((ref) {
  final mode = ref.watch(activeRoutingModeProvider);
  final tag = ref.watch(activeProxyNotifierProvider.select((proxy) => proxy.value?.tag));
  if (tag == null || tag.isEmpty) return null;
  return mode == 'balance' ? 'balance' : tag;
});

final youtubeReportProvider = FutureProvider.autoDispose<YoutubeReport?>((ref) async {
  final running = ref.watch(serviceRunningProvider);
  ref.watch(activeProfileProvider.select((profile) => profile.value?.id));
  final route = ref.watch(availabilityRouteProvider);
  // A status transition invalidates results even if a reconnect uses the same profile.
  ref.watch(connectionNotifierProvider);
  if (!running || route == null) return null;
  final tag = ref.read(activeProxyNotifierProvider).value?.tag;
  if (tag == null || tag.isEmpty) return null;
  final call = ref.read(hiddifyCoreServiceProvider).core.bgClient.checkAvailability(tag);
  ref.onDispose(() => unawaited(call.cancel().catchError((Object _) {})));
  final response = await call;
  return decodeAvailabilityReport(response.message, expectedTag: tag);
});

YoutubeReport decodeAvailabilityReport(String encoded, {required String expectedTag}) {
  final data = jsonDecode(encoded) as Map<String, dynamic>;
  if (data['tag'] != expectedTag) throw const FormatException('Availability server mismatch');
  final checks = (data['checks'] as List).cast<Map<String, dynamic>>();
  if (checks.length != 2) throw const FormatException('Incomplete availability report');
  return YoutubeReport([
    for (final check in checks)
      ProbeResult(
        label: check['label'] as String,
        outcome: ProbeOutcome.values.byName(check['outcome'] as String),
        elapsed: Duration(milliseconds: (check['elapsed_ms'] as num).toInt()),
        statusCode: (check['status_code'] as num?)?.toInt(),
        tlsReason: check['tls_reason'] == null ? null : TlsFailureReason.values.byName(check['tls_reason'] as String),
        isThumbnail: check['is_thumbnail'] as bool,
      ),
  ], configurationTag: expectedTag);
}
