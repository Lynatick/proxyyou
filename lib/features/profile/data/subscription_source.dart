import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/utils/link_parsers.dart';

class SubscriptionInspection {
  const SubscriptionInspection(this.hash, this.headers, this.remoteLines);
  final String hash;
  final Map<String, dynamic> headers;
  // Keep lines only for an aggregate subscription containing embedded URLs.
  final List<String>? remoteLines;
}

Map<String, dynamic> subscriptionContentHeaders(String content) {
  final decoded = safeDecodeBase64(content);
  final headers = <String, dynamic>{};
  var offset = 0;
  for (var i = 0; i < 10 && offset < decoded.length; i++) {
    final end = decoded.indexOf('\n', offset);
    final line = decoded.substring(offset, end < 0 ? decoded.length : end);
    if (line.startsWith('#') || line.startsWith('//')) {
      final colon = line.indexOf(':');
      if (colon >= 0) {
        final key = line.substring(0, colon).replaceFirst(RegExp('^#|//'), '').trim().toLowerCase();
        headers[key] = line.substring(colon + 1).trim();
      }
    }
    if (end < 0) break;
    offset = end + 1;
  }
  return headers;
}

// One file read supplies digest, metadata and optional aggregate URL lines.
// Neither the complete body nor JSON objects cross back to the UI isolate.
Future<SubscriptionInspection> inspectSubscriptionSource(String path) => Isolate.run(() {
  final bytes = File(path).readAsBytesSync();
  final content = utf8.decode(bytes);
  final first = content.trimLeft();
  final structured = first.startsWith('{') || first.startsWith('[');
  final lines = !structured && RegExp('^https?://', multiLine: true).hasMatch(content) ? content.split('\n') : null;
  return SubscriptionInspection(sha256.convert(bytes).toString(), subscriptionContentHeaders(content), lines);
});

class DownloadedSubscription {
  const DownloadedSubscription(this.inspection, this.headers);
  final SubscriptionInspection inspection;
  final Map<String, dynamic> headers;
}

class _SourceEntry {
  _SourceEntry(this.directory, this.file, this.source, this.expires);
  final Directory directory;
  final File file;
  final DownloadedSubscription source;
  final DateTime expires;
  Timer? timer;
}

/// Short-lived, private downloaded files. No configuration is installed here.
/// A source is claimed by one importer; later checks cannot delete its file.
class SubscriptionSourceCache {
  SubscriptionSourceCache({this.ttl = const Duration(minutes: 5), this.maxEntries = 3});
  static final _clients = Expando<SubscriptionSourceCache>();
  factory SubscriptionSourceCache.forClient(DioHttpClient client) => _clients[client] ??= SubscriptionSourceCache();
  final Duration ttl;
  final int maxEntries;
  final _entries = <String, _SourceEntry>{};
  final _epochs = <String, int>{};
  String _key(String url, String userAgent) => '$userAgent\n${url.trim()}';
  int epoch(String url, String userAgent) => _epochs.putIfAbsent(_key(url, userAgent), () => 0);

  void invalidate(String url, String userAgent) {
    final key = _key(url, userAgent);
    _epochs[key] = (_epochs[key] ?? 0) + 1;
    final old = _entries.remove(key);
    if (old != null) unawaited(_discard(old));
  }

  bool retain(
    String url,
    String userAgent,
    int expectedEpoch,
    Directory directory,
    File file,
    SubscriptionInspection inspection,
    Map<String, dynamic> headers,
  ) {
    final key = _key(url, userAgent);
    if ((_epochs[key] ?? 0) != expectedEpoch || maxEntries < 1) return false;
    final old = _entries.remove(key);
    if (old != null) unawaited(_discard(old));
    while (_entries.length >= maxEntries) {
      final oldest = _entries.remove(_entries.keys.first)!;
      unawaited(_discard(oldest));
    }
    final entry = _SourceEntry(
      directory,
      file,
      DownloadedSubscription(inspection, Map<String, dynamic>.of(headers)),
      DateTime.now().add(ttl),
    );
    _entries[key] = entry;
    entry.timer = Timer(ttl, () {
      if (identical(_entries[key], entry)) _entries.remove(key);
      unawaited(_discard(entry));
    });
    return true;
  }

  Future<DownloadedSubscription?> take(String url, String userAgent, String destination) async {
    final key = _key(url, userAgent);
    final entry = _entries.remove(key);
    _epochs[key] = (_epochs[key] ?? 0) + 1;
    if (entry == null) return null;
    entry.timer?.cancel();
    try {
      if (DateTime.now().isAfter(entry.expires) || !await entry.file.exists()) return null;
      try {
        await entry.file.rename(destination);
      } on FileSystemException {
        await entry.file.copy(destination);
      }
      return entry.source;
    } finally {
      await _discard(entry);
    }
  }

  Future<void> clear() async {
    final entries = _entries.values.toList();
    _entries.clear();
    for (final key in _epochs.keys.toList()) {
      _epochs[key] = _epochs[key]! + 1;
    }
    await Future.wait(entries.map(_discard));
  }

  Future<void> _discard(_SourceEntry entry) async {
    entry.timer?.cancel();
    try {
      if (await entry.directory.exists()) await entry.directory.delete(recursive: true);
    } on FileSystemException {
      // Cache cleanup never replaces an import result with a filesystem error.
    }
  }
}
