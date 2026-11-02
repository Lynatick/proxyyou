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
  return _decodedHeaders(safeDecodeBase64(content));
}

Map<String, dynamic> _decodedHeaders(String decoded) {
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

// Ordinary subscriptions take one streaming pass, with bounded metadata memory.
// Only URL aggregators need a second pass to retain their expansion lines: we
// cannot retain every ordinary URI line just in case a URL appears at the end.
Future<SubscriptionInspection> inspectSubscriptionSource(String path) => Isolate.run(() async {
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  final plain = _InspectionSink();
  final decoded = _InspectionSink();
  Sink<String>? encoded = base64.decoder.startChunkedConversion(utf8.decoder.startChunkedConversion(decoded));
  final text = utf8.decoder.startChunkedConversion(
    _TextSink((chunk) {
      plain.add(chunk);
      try {
        encoded?.add(chunk);
      } on FormatException {
        encoded = null;
      }
    }),
  );
  await for (final chunk in File(path).openRead()) {
    hash.add(chunk);
    text.add(chunk);
  }
  hash.close();
  text.close();
  try {
    encoded?.close();
  } on FormatException {
    encoded = null;
  }
  List<String>? lines;
  if (!plain.structured && plain.hasRemoteUrl) {
    lines = <String>[];
    var tail = '';
    await for (final chunk in File(path).openRead().transform(utf8.decoder)) {
      final parts = (tail + chunk).split('\n');
      tail = parts.removeLast();
      lines.addAll(parts);
    }
    lines.add(tail);
  }
  return SubscriptionInspection(
    digest.value!.toString(),
    _decodedHeaders((encoded == null ? plain : decoded).prefix.toString()),
    lines,
  );
});

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _TextSink implements Sink<String> {
  _TextSink(this.receive);
  final void Function(String) receive;
  @override
  void add(String data) => receive(data);
  @override
  void close() {}
}

class _InspectionSink implements Sink<String> {
  final prefix = StringBuffer();
  int _lines = 0;
  bool _formatKnown = false;
  bool structured = false;
  bool hasRemoteUrl = false;
  String _lineStart = '';

  @override
  void add(String chunk) {
    if (!_formatKnown) {
      final first = chunk.trimLeft();
      if (first.isNotEmpty) {
        structured = first.startsWith('{') || first.startsWith('[');
        _formatKnown = true;
      }
    }
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf('\n', start);
      final end = newline < 0 ? chunk.length : newline;
      if (_lineStart.length < 8) {
        final remaining = 8 - _lineStart.length;
        _lineStart += chunk.substring(start, end - start > remaining ? start + remaining : end);
        hasRemoteUrl |= _lineStart.startsWith('http://') || _lineStart.startsWith('https://');
      }
      // Metadata is limited to ten lines and 64 KiB, including a giant JSON line.
      if (_lines < 10 && prefix.length < 65536) {
        final stop = newline < 0 ? end : end + 1;
        final remaining = 65536 - prefix.length;
        prefix.write(chunk.substring(start, stop - start > remaining ? start + remaining : stop));
      }
      if (newline < 0) break;
      _lines++;
      _lineStart = '';
      start = newline + 1;
    }
  }

  @override
  void close() {}
}

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
