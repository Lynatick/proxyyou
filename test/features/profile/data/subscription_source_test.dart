import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/data/subscription_revision_checker.dart';
import 'package:hiddify/features/profile/data/subscription_source.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory directory;
  setUp(() async => directory = await Directory.systemTemp.createTemp('proxyyou-source-test-'));
  tearDown(() => directory.delete(recursive: true));

  test('one inspection retains source digest and first ten headers without expanding JSON URLs', () async {
    const content = '// profile-title: Test\n{"outbounds":[],"url":"https://example.invalid/sub"}';
    final file = await File('${directory.path}/source').writeAsString(content);
    final result = await inspectSubscriptionSource(file.path);
    expect(result.hash, sha256.convert(utf8.encode(content)).toString());
    expect(result.headers['profile-title'], 'Test');
    expect(result.remoteLines, isNull);
    expect(
      subscriptionContentHeaders(base64Encode(utf8.encode('# profile-title: Encoded\nvless://x')))['profile-title'],
      'Encoded',
    );
    expect(subscriptionContentHeaders('${'line\n' * 10}# profile-title: too late'), isEmpty);
  });

  test('aggregate expansion lines preserve ordering; ordinary URI subscriptions need no extra read', () async {
    final file = await File('${directory.path}/source').writeAsString('vless://one\nhttps://example.invalid/sub');
    expect((await inspectSubscriptionSource(file.path)).remoteLines, ['vless://one', 'https://example.invalid/sub']);
    await file.writeAsString('vless://one\nvless://two');
    expect((await inspectSubscriptionSource(file.path)).remoteLines, isNull);
  });

  test('cached file has one owner and respects URL, user agent and invalidation', () async {
    final cache = SubscriptionSourceCache();
    addTearDown(cache.clear);
    final sourceDirectory = await directory.createTemp('owned-');
    final source = await File('${sourceDirectory.path}/source').writeAsString('vless://one');
    final inspected = await inspectSubscriptionSource(source.path);
    expect(cache.retain('https://one', 'agent', 0, sourceDirectory, source, inspected, {}), isTrue);
    expect(await cache.take('https://two', 'agent', '${directory.path}/wrong'), isNull);
    expect(await cache.take('https://one', 'different', '${directory.path}/wrong'), isNull);
    final destination = '${directory.path}/claimed';
    expect((await cache.take('https://one', 'agent', destination))?.inspection.hash, inspected.hash);
    expect(await File(destination).readAsString(), 'vless://one');
    expect(await cache.take('https://one', 'agent', '${directory.path}/again'), isNull);
    final rejected = await directory.createTemp('rejected-');
    final rejectedFile = await File('${rejected.path}/source').writeAsString('older response');
    expect(cache.retain('https://one', 'agent', 0, rejected, rejectedFile, inspected, {}), isFalse);
  });

  test('expiry discards an observed file rather than installing stale contents', () async {
    final cache = SubscriptionSourceCache(ttl: Duration.zero);
    addTearDown(cache.clear);
    final owned = await directory.createTemp('expired-');
    final file = await File('${owned.path}/source').writeAsString('old');
    cache.retain('url', 'agent', 0, owned, file, await inspectSubscriptionSource(file.path), {});
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(await cache.take('url', 'agent', '${directory.path}/output'), isNull);
  });

  test('manual import claims the update-check download without a second HTTP request', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences))],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    var requests = 0;
    const body = '{"outbounds":[{"type":"socks","tag":"test","server":"127.0.0.1","server_port":9001}]}';
    origin.listen((request) async {
      requests++;
      request.response.headers.set('profile-title', 'Downloaded once');
      request.response.write(body);
      await request.response.close();
    });
    final client = DioHttpClient(timeout: const Duration(seconds: 2), userAgent: 'ProxyYou-test', debug: false);
    addTearDown(SubscriptionSourceCache.forClient(client).clear);
    final url = 'http://127.0.0.1:${origin.port}/subscription';
    final profile = ProfileEntity.remote(
      id: 'one',
      active: true,
      name: 'old',
      url: url,
      lastUpdate: DateTime(2026),
    ) as RemoteProfileEntity;
    final checker = SubscriptionRevisionChecker(client, preferences);
    await checker.check(profile, CancelToken());
    final provider = Provider((ref) => ProfileParser(ref: ref, httpClient: client));
    final destination = '${directory.path}/import';
    final result = await container
        .read(provider)
        .addRemote(id: 'one', url: url, tempFilePath: destination, userOverride: null)
        .run();
    expect(result.isRight(), isTrue);
    expect(result.getOrElse((error) => throw error).name, 'Downloaded once');
    expect(requests, 1);
    expect(await File(destination).readAsString(), body);
  });
}
