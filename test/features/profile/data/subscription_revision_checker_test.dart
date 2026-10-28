import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/profile/data/subscription_fingerprint.dart';
import 'package:hiddify/features/profile/data/subscription_revision_checker.dart';
import 'package:hiddify/features/profile/data/subscription_source.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late HttpServer origin;
  late SubscriptionRevisionChecker checker;
  late RemoteProfileEntity profile;
  var body = 'original';
  String? etag = '"v1"';
  var status = 200;
  var requests = 0;
  String? condition;
  final originalHash = sha256.convert(utf8.encode('original')).toString();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    body = 'original';
    etag = '"v1"';
    status = 200;
    requests = 0;
    condition = null;
    origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin.listen((request) async {
      requests++;
      condition = request.headers.value('if-none-match');
      expect(request.headers.value('user-agent'), 'ProxyYou-test');
      if (status != 200) {
        request.response.statusCode = status;
      } else if (etag != null && condition == etag) {
        request.response.statusCode = 304;
      } else {
        if (etag != null) request.response.headers.set('etag', etag!);
        request.response.write(body);
      }
      await request.response.close();
    });
    checker = SubscriptionRevisionChecker(
      DioHttpClient(timeout: const Duration(seconds: 2), userAgent: 'ProxyYou-test', debug: false),
      await SharedPreferences.getInstance(),
    );
    profile = ProfileEntity.remote(
      id: 'one',
      active: true,
      name: 'Subscription',
      url: 'http://127.0.0.1:${origin.port}/source',
      lastUpdate: DateTime(2026),
      populatedHeaders: {subscriptionSourceHash: originalHash},
    ) as RemoteProfileEntity;
  });
  tearDown(() async {
    await SubscriptionSourceCache.forClient(checker.client).clear();
    await origin.close(force: true);
  });

  test('changed source is indicated, 304 preserves it, successful import clears it', () async {
    expect((await checker.check(profile, CancelToken())).available, isFalse);
    expect(requests, 1);
    body = 'changed';
    etag = '"v2"';
    final changed = await checker.check(profile, CancelToken());
    expect(changed.available, isTrue);
    expect(condition, '"v1"');
    expect(profile.populatedHeaders![subscriptionSourceHash], originalHash);
    expect((await checker.check(profile, CancelToken())).available, isTrue);
    expect(condition, '"v2"');
    final imported = profile.copyWith(populatedHeaders: {subscriptionSourceHash: changed.observed});
    expect(checker.cached(imported)?.available, isFalse);
    expect((await checker.check(imported, CancelToken())).available, isFalse);
  });
  test('a changed ETag without content changes is not an update', () async {
    await checker.check(profile, CancelToken());
    etag = '"metadata-only"';
    expect((await checker.check(profile, CancelToken())).available, isFalse);
  });
  test('servers without validators are compared by streamed source digest', () async {
    etag = null;
    expect((await checker.check(profile, CancelToken())).available, isFalse);
    body = 'different';
    expect((await checker.check(profile, CancelToken())).available, isTrue);
    expect(condition, isNull);
  });
  test('older subscriptions establish a baseline without installing or claiming changes', () async {
    profile = profile.copyWith(populatedHeaders: null);
    body = 'unknown-original';
    expect((await checker.check(profile, CancelToken())).available, isFalse);
    body = 'later-change';
    etag = '"later"';
    expect((await checker.check(profile, CancelToken())).available, isTrue);
  });
  test('HTTP failure preserves a known available update', () async {
    body = 'changed';
    expect((await checker.check(profile, CancelToken())).available, isTrue);
    status = 403;
    await expectLater(checker.check(profile, CancelToken()), throwsA(isA<DioException>()));
    expect(checker.cached(profile)?.available, isTrue);
  });
  test('cancelled check cannot overwrite its cached revision', () async {
    final cancel = CancelToken()..cancel();
    await expectLater(checker.check(profile, cancel), throwsA(isA<DioException>()));
    expect(checker.cached(profile), isNull);
  });
  test('different URLs never reuse another source validator', () async {
    await checker.check(profile, CancelToken());
    await checker.check(profile.copyWith(url: '${profile.url}?new'), CancelToken());
    expect(condition, isNull);
  });
}
