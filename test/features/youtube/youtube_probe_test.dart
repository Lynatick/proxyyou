import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_test_video.dart';

// Only this test process trusts this fixture. Production uses system TLS roots.
const fixture = 'test/features/youtube/fixtures/localhost';

void main() {
  test('YouTube and thumbnail timings use separate HTTPS targets', () {
    expect(YoutubeProbe.targets, hasLength(2));
    expect(YoutubeProbe.targets.first.url, 'https://www.youtube.com/generate_204');
    expect(YoutubeProbe.targets.first.expectedStatus, 204);
    expect(YoutubeProbe.targets.last.jpeg, isTrue);
    expect(Uri.parse(YoutubeProbe.targets.last.url).host, 'i.ytimg.com');
    expect(Uri.parse(YoutubeProbe.targets.last.url).path, '/vi/$youtubeTestVideoId/hqdefault.jpg');
  });

  late HttpServer origin;
  late ServerSocket proxy;
  final sockets = <Socket>[];
  var connectCount = 0;
  var responseStatus = 204;
  var responseBody = <int>[];
  String? contentType;
  var stall = false;

  final trustedContext = SecurityContext()..setTrustedCertificates('test/features/youtube/fixtures/ca.crt');

  setUp(() async {
    connectCount = 0;
    responseStatus = 204;
    responseBody = [];
    contentType = null;
    stall = false;
    final context = SecurityContext()
      ..useCertificateChain('$fixture.crt')
      ..usePrivateKey('$fixture.key');
    origin = await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context);
    origin.listen((request) async {
      if (stall) return;
      request.response.statusCode = responseStatus;
      if (contentType != null) request.response.headers.set(HttpHeaders.contentTypeHeader, contentType!);
      request.response.add(responseBody);
      await request.response.close();
    });
    proxy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    proxy.listen((socket) {
      sockets.add(socket);
      final header = <int>[];
      var forwarding = false;
      Socket? upstream;
      socket.listen(
        (data) async {
          if (forwarding) {
            upstream?.add(data);
            return;
          }
          header.addAll(data);
          if (!ascii.decode(header).contains('\r\n\r\n')) return;
          forwarding = true;
          expect(ascii.decode(header), startsWith('CONNECT localhost:${origin.port} HTTP/1.1'));
          connectCount++;
          upstream = await Socket.connect(InternetAddress.loopbackIPv4, origin.port);
          sockets.add(upstream!);
          socket.add(ascii.encode('HTTP/1.1 200 Connection Established\r\n\r\n'));
          upstream!.listen(socket.add, onDone: socket.destroy, onError: (_) => socket.destroy());
        },
        onDone: () => upstream?.destroy(),
        onError: (_) => upstream?.destroy(),
      );
    });
  });

  tearDown(() async {
    for (final socket in sockets) {
      socket.destroy();
    }
    sockets.clear();
    await proxy.close();
    await origin.close(force: true);
  });

  ProbeTarget target({int status = 204, bool jpeg = false}) =>
      ProbeTarget('fixture', 'https://localhost:${origin.port}/check', expectedStatus: status, jpeg: jpeg);

  test('CONNECT is used and a valid origin response succeeds', () async {
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    final result = await probe.checkTarget(target());
    expect(result.outcome, ProbeOutcome.reachable);
    expect(result.statusCode, 204);
    expect(connectCount, 1);
  });

  test('untrusted TLS certificates are rejected', () async {
    final probe = YoutubeProbe(proxyPort: proxy.port, securityContext: SecurityContext());
    addTearDown(probe.close);
    final result = await probe.checkTarget(target());
    expect(result.outcome, ProbeOutcome.tlsFailure);
    expect(result.tlsReason, TlsFailureReason.untrustedCertificate);
  });

  test('closed TLS transport is not misreported as an untrusted certificate', () {
    expect(
      classifyTlsFailure('HandshakeException: Connection terminated during handshake'),
      TlsFailureReason.connectionClosed,
    );
    expect(
      classifyTlsFailure('CERTIFICATE_VERIFY_FAILED: certificate has expired'),
      TlsFailureReason.certificateExpired,
    );
    expect(classifyTlsFailure('CERTIFICATE_VERIFY_FAILED: Hostname mismatch'), TlsFailureReason.hostnameMismatch);
  });

  test('a dead proxy never falls back to the reachable origin', () async {
    final deadPort = proxy.port;
    await proxy.close();
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: deadPort);
    addTearDown(probe.close);
    final result = await probe.checkTarget(target());
    expect(result.outcome, ProbeOutcome.networkFailure);
    expect(connectCount, 0);
  });

  test('403 and redirects cannot be reported as reachable', () async {
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    for (final status in [403, 302, 429, 500]) {
      responseStatus = status;
      final result = await probe.checkTarget(target());
      expect(result.outcome, ProbeOutcome.rejected);
      expect(result.statusCode, status);
    }
  });

  test('HTML masquerading as a thumbnail is rejected', () async {
    responseStatus = 200;
    responseBody = utf8.encode('<html>blocked</html>');
    contentType = 'text/html';
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    expect((await probe.checkTarget(target(status: 200, jpeg: true))).outcome, ProbeOutcome.unexpectedResponse);
  });

  test('JPEG prefix and content type are required for thumbnail connectivity', () async {
    responseStatus = 200;
    responseBody = [0xff, 0xd8, 0xff, 0xe0, 0, 0];
    contentType = 'image/jpeg';
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    expect((await probe.checkTarget(target(status: 200, jpeg: true))).outcome, ProbeOutcome.reachable);
  });

  test('404 JPEG placeholder identifies a missing thumbnail without proving connectivity failure', () async {
    responseStatus = 404;
    responseBody = [0xff, 0xd8, 0xff, 0xe0, 0, 0];
    contentType = 'image/jpeg';
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    final result = await probe.checkTarget(target(status: 200, jpeg: true));
    expect(result.outcome, ProbeOutcome.rejected);
    expect(result.missingThumbnail, isTrue);
    expect(result.reachable, isFalse);
    final report = YoutubeReport([
      const ProbeResult(label: 'YouTube', outcome: ProbeOutcome.reachable, elapsed: Duration(milliseconds: 50)),
      result,
    ]);
    expect(report.onlyThumbnailMissing, isTrue);
    expect(report.reachable, isFalse);
  });

  test('thumbnail 404 does not hide a separate network failure', () {
    const missing = ProbeResult(
      label: 'Миниатюры',
      outcome: ProbeOutcome.rejected,
      elapsed: Duration.zero,
      statusCode: 404,
      isThumbnail: true,
    );
    const failed = ProbeResult(label: 'YouTube', outcome: ProbeOutcome.networkFailure, elapsed: Duration.zero);
    expect(YoutubeReport([failed, missing]).onlyThumbnailMissing, isFalse);
    expect(
      const ProbeResult(
        label: 'YouTube',
        outcome: ProbeOutcome.rejected,
        elapsed: Duration.zero,
        statusCode: 404,
      ).missingThumbnail,
      isFalse,
    );
  });

  test('large responses are bounded', () async {
    responseStatus = 200;
    responseBody = List.filled(300 * 1024, 0);
    contentType = 'image/jpeg';
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    expect((await probe.checkTarget(target(status: 200, jpeg: true))).outcome, ProbeOutcome.unexpectedResponse);
  });

  test('an origin that never responds times out', () async {
    stall = true;
    final probe = YoutubeProbe(
      securityContext: trustedContext,
      proxyPort: proxy.port,
      timeout: const Duration(milliseconds: 300),
    );
    addTearDown(probe.close);
    expect((await probe.checkTarget(target())).outcome, ProbeOutcome.timeout);
  });

  test('closing a probe terminates in-flight sockets', () async {
    stall = true;
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    final result = probe.checkTarget(target());
    await Future<void>.delayed(const Duration(milliseconds: 100));
    probe.close();
    expect((await result).outcome, ProbeOutcome.networkFailure);
    await expectLater(probe.checkTarget(target()), throwsStateError);
  });

  test('invalid port and non-HTTPS targets are refused', () async {
    expect(() => YoutubeProbe(securityContext: trustedContext, proxyPort: 0), throwsArgumentError);
    final probe = YoutubeProbe(securityContext: trustedContext, proxyPort: proxy.port);
    addTearDown(probe.close);
    await expectLater(
      probe.checkTarget(const ProbeTarget('bad', 'http://localhost/', expectedStatus: 200)),
      throwsArgumentError,
    );
  });
}
