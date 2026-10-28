import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/subscription_fingerprint.dart';
import 'package:hiddify/features/profile/data/subscription_source.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SubscriptionRevision {
  const SubscriptionRevision({required this.baseline, required this.observed, this.etag, this.modified});
  final String baseline;
  final String observed;
  final String? etag;
  final String? modified;
  bool get available => baseline != observed;
  Map<String, dynamic> toJson() => {'baseline': baseline, 'observed': observed, 'etag': etag, 'modified': modified};
}

String? appliedSubscriptionHash(RemoteProfileEntity profile) {
  final value = profile.populatedHeaders?[subscriptionSourceHash];
  return value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value) ? value : null;
}

String? _header(RemoteProfileEntity profile, String name) {
  final value = profile.populatedHeaders?[name];
  return value is String ? value : null;
}

/// Observes the source only. It never parses, installs, or applies core options.
class SubscriptionRevisionChecker {
  SubscriptionRevisionChecker(this.client, this.preferences, {this.userAgent});
  final DioHttpClient client;
  final SharedPreferences preferences;
  final String? userAgent;
  static const maxBytes = 64 * 1024 * 1024;
  String _key(RemoteProfileEntity p) => 'subscription_revision_v1_${sha256.convert(utf8.encode('${p.id}\n${p.url}'))}';

  SubscriptionRevision? cached(RemoteProfileEntity profile) {
    try {
      final raw = preferences.getString(_key(profile));
      if (raw == null) return null;
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final applied = appliedSubscriptionHash(profile);
      if (applied != null && applied != data['baseline'] && applied != data['observed']) {
        return SubscriptionRevision(
          baseline: applied,
          observed: applied,
          etag: _header(profile, 'etag'),
          modified: _header(profile, 'last-modified'),
        );
      }
      return SubscriptionRevision(
        baseline: applied ?? data['baseline'] as String,
        observed: data['observed'] as String,
        etag: data['etag'] as String?,
        modified: data['modified'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  Future<SubscriptionRevision> check(RemoteProfileEntity profile, CancelToken cancelToken) async {
    final previous = cached(profile);
    final applied = appliedSubscriptionHash(profile);
    final observed = previous?.observed ?? applied;
    final etag = previous?.etag ?? (applied != null ? _header(profile, 'etag') : null);
    final modified = previous?.modified ?? (applied != null ? _header(profile, 'last-modified') : null);
    final cache = SubscriptionSourceCache.forClient(client);
    final agent = userAgent ?? client.userAgent;
    final epoch = cache.epoch(profile.url, agent);
    var retained = false;
    final directory = await Directory.systemTemp.createTemp('proxyyou-subscription-check-');
    final file = File('${directory.path}/source');
    try {
      final response = await client.download(
        profile.url,
        file.path,
        userAgent: userAgent,
        cancelToken: cancelToken,
        acceptNotModified: true,
        maxBytes: maxBytes,
        headers: {
          if (observed != null && etag != null) 'If-None-Match': etag,
          if (observed != null && etag == null && modified != null) 'If-Modified-Since': modified,
        },
      );
      final SubscriptionRevision result;
      if (response.statusCode == 304) {
        if (observed == null) throw StateError('304 without a known subscription revision');
        result = SubscriptionRevision(
          baseline: applied ?? previous!.baseline,
          observed: observed,
          etag: etag,
          modified: modified,
        );
      } else {
        if (await file.length() > maxBytes) throw StateError('Subscription exceeds size limit');
        final inspection = await inspectSubscriptionSource(file.path);
        final digest = inspection.hash;
        if (cancelToken.isCancelled) throw cancelToken.cancelError!;
        retained = cache.retain(
          profile.url,
          agent,
          epoch,
          directory,
          file,
          inspection,
          response.headers.map.map((key, value) => MapEntry(key, value.length == 1 ? value.first : value)),
        );
        result = SubscriptionRevision(
          // Old installations have no original source digest. Establish a
          // comparison baseline, without claiming an update or applying it.
          baseline: applied ?? previous?.baseline ?? digest,
          observed: digest,
          etag: response.headers.value('etag'),
          modified: response.headers.value('last-modified'),
        );
      }
      if (cancelToken.isCancelled) throw cancelToken.cancelError!;
      await preferences.setString(_key(profile), jsonEncode(result.toJson()));
      return result;
    } finally {
      if (!retained) await directory.delete(recursive: true);
    }
  }
}
