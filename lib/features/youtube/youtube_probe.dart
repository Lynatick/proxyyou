import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/youtube/youtube_test_video.dart';

/// Checks origin connectivity through the core's HTTP CONNECT inbound.
/// A successful probe does not certify that a particular video can be played.
enum ProbeOutcome { skipped, reachable, rejected, unexpectedResponse, timeout, tlsFailure, networkFailure }

enum TlsFailureReason { certificateExpired, hostnameMismatch, untrustedCertificate, connectionClosed, handshake }

TlsFailureReason classifyTlsFailure(String message) {
  final text = message.toLowerCase();
  if (text.contains('certificate has expired') || text.contains('certificate expired')) {
    return TlsFailureReason.certificateExpired;
  }
  if (text.contains('hostname mismatch')) return TlsFailureReason.hostnameMismatch;
  if (text.contains('certificate_verify_failed') || text.contains('unknown ca')) {
    return TlsFailureReason.untrustedCertificate;
  }
  if (text.contains('connection terminated during handshake') || text.contains('connection closed')) {
    return TlsFailureReason.connectionClosed;
  }
  return TlsFailureReason.handshake;
}

class ProbeResult {
  const ProbeResult({
    required this.label,
    required this.outcome,
    required this.elapsed,
    this.statusCode,
    this.tlsReason,
    this.isThumbnail = false,
  });
  final String label;
  final ProbeOutcome outcome;
  final Duration elapsed;
  final int? statusCode;
  final TlsFailureReason? tlsReason;
  final bool isThumbnail;
  bool get reachable => outcome == ProbeOutcome.reachable;
  bool get missingThumbnail => isThumbnail && outcome == ProbeOutcome.rejected && statusCode == 404;
}

class YoutubeReport {
  YoutubeReport(List<ProbeResult> checks, {this.configurationTag, this.ping, this.interval, this.ticket})
    : checks = List.unmodifiable(checks),
      checkedAt = DateTime.now();
  final String? configurationTag;
  final ProbeResult? ping;
  final Duration? interval;
  final String? ticket;
  final List<ProbeResult> checks;
  final DateTime checkedAt;
  bool get reachable =>
      (ping == null || ping!.reachable) && checks.length == 2 && checks.every((check) => check.reachable);
  bool get onlyThumbnailMissing =>
      checks.any((check) => check.missingThumbnail) &&
      checks.every((check) => check.reachable || check.missingThumbnail);
}

class ProbeTarget {
  const ProbeTarget(this.label, this.url, {required this.expectedStatus, this.jpeg = false});
  final String label;
  final String url;
  final int expectedStatus;
  final bool jpeg;
}

class YoutubeProbe {
  YoutubeProbe({required this.proxyPort, this.timeout = const Duration(seconds: 12), this.securityContext}) {
    if (proxyPort < 1 || proxyPort > 65535) throw ArgumentError.value(proxyPort, 'proxyPort');
    if (timeout <= Duration.zero) throw ArgumentError.value(timeout, 'timeout');
  }

  final SecurityContext? securityContext;
  final int proxyPort;
  final Duration timeout;
  final Set<HttpClient> _clients = {};
  bool _closed = false;

  static const targets = [
    ProbeTarget('YouTube', 'https://www.youtube.com/generate_204', expectedStatus: 204),
    ProbeTarget('Миниатюры', youtubeTestThumbnailUrl, expectedStatus: 200, jpeg: true),
  ];

  Future<YoutubeReport> check() async {
    final results = <ProbeResult>[];
    for (final target in targets) {
      final result = await checkTarget(target);
      results.add(result);
      if (!result.reachable) break;
    }
    return YoutubeReport(results);
  }

  /// No DIRECT fallback, no global proxy mutation, normal TLS verification.
  Future<ProbeResult> checkTarget(ProbeTarget target) async {
    if (_closed) throw StateError('Probe has been closed');
    final uri = Uri.parse(target.url);
    if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
      throw ArgumentError.value(target.url, 'url', 'An HTTPS URL without credentials is required');
    }
    final clock = Stopwatch()..start();
    final client = HttpClient(context: securityContext)
      ..connectionTimeout = timeout
      ..findProxy = (_) => 'PROXY 127.0.0.1:$proxyPort';
    _clients.add(client);
    int? status;
    ProbeResult result(ProbeOutcome outcome) => ProbeResult(
      label: target.label,
      outcome: outcome,
      elapsed: clock.elapsed,
      statusCode: status,
      isThumbnail: target.jpeg,
    );
    try {
      return await (() async {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.userAgentHeader, 'ProxyYou/0.1 connectivity-check');
        final response = await request.close();
        status = response.statusCode;
        if (status != target.expectedStatus) return result(ProbeOutcome.rejected);
        var size = 0;
        final prefix = <int>[];
        await for (final bytes in response) {
          size += bytes.length;
          if (size > 256 * 1024) return result(ProbeOutcome.unexpectedResponse);
          for (final byte in bytes) {
            if (prefix.length == 3) break;
            prefix.add(byte);
          }
        }
        final valid = target.jpeg
            ? response.headers.contentType?.mimeType == 'image/jpeg' &&
                  prefix.length == 3 &&
                  prefix[0] == 0xff &&
                  prefix[1] == 0xd8 &&
                  prefix[2] == 0xff
            : size == 0;
        return result(valid ? ProbeOutcome.reachable : ProbeOutcome.unexpectedResponse);
      })().timeout(timeout);
    } on TimeoutException {
      return result(ProbeOutcome.timeout);
    } on HandshakeException catch (error) {
      return ProbeResult(
        label: target.label,
        outcome: ProbeOutcome.tlsFailure,
        elapsed: clock.elapsed,
        tlsReason: classifyTlsFailure(error.toString()),
        isThumbnail: target.jpeg,
      );
    } on IOException {
      return result(ProbeOutcome.networkFailure);
    } finally {
      clock.stop();
      _clients.remove(client);
      client.close(force: true);
    }
  }

  /// Cancels sockets when the connection, profile or outbound changes.
  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
