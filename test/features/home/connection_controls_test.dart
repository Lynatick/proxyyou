import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/home/widget/connection_controls.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/proxy/data/proxy_repository.dart';
import 'package:hiddify/features/proxy/model/proxy_failure.dart';
import 'package:hiddify/features/proxy/overview/proxies_overview_notifier.dart';
import 'package:hiddify/features/tv/tv_mode.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class TestConnection extends ConnectionNotifier {
  TestConnection(this.status);
  final ConnectionStatus status;
  @override
  Stream<ConnectionStatus> build() => Stream.value(status);
}

class TestProfile extends ActiveProfile {
  @override
  Stream<ProfileEntity?> build() => Stream.value(
    ProfileEntity.local(id: 'test', active: true, name: 'Test subscription', lastUpdate: DateTime(2026)),
  );
}

class TestActiveProxy extends ActiveProxyNotifier {
  TestActiveProxy([this.delay = 123]);
  final int delay;
  @override
  Stream<OutboundInfo> build() => Stream.value(OutboundInfo(tag: 'selected-server', urlTestDelay: delay));
}

class TestGroup extends ProxiesOverviewNotifier {
  @override
  Stream<OutboundGroup?> build() => throw StateError('Home must not subscribe to the full sorted list');
}

class TestRepository implements ProxyRepository {
  final groups = <String>[];
  final pending = Completer<Unit>();
  @override
  Stream<Either<ProxyFailure, OutboundGroup?>> watchProxies() =>
      Stream.value(Right(OutboundGroup(tag: 'subscription-group')));
  @override
  TaskEither<ProxyFailure, Unit> urlTest(String groupTag) => TaskEither(() async {
    groups.add(groupTag);
    return Right(await pending.future);
  });
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test('ping belongs to the selected server rather than its balancer', () {
    final result = connectedOutbound([
      OutboundGroup(
        tag: 'select',
        selected: 'balancer',
        items: [OutboundInfo(tag: 'balancer', isGroup: true, urlTestDelay: 20)],
      ),
      OutboundGroup(
        tag: 'balancer',
        selected: 'server',
        items: [OutboundInfo(tag: 'server', urlTestDelay: 89)],
      ),
    ]);
    expect(result.tag, 'server');
    expect(result.urlTestDelay, 89);
    expect(connectedOutbound([OutboundGroup()]).urlTestDelay, 0);
  });

  test('home follows the main selection and ignores unrelated balancer leaves', () {
    final chosen = OutboundInfo(tag: 'chosen', urlTestDelay: 91);
    expect(
      connectedOutbound([
        OutboundGroup(tag: 'select', selected: 'chosen', items: [chosen]),
        OutboundGroup(
          tag: 'lowest',
          selected: 'other',
          items: [OutboundInfo(tag: 'other', urlTestDelay: 25)],
        ),
      ]).tag,
      'chosen',
    );
    expect(
      connectedOutbound([
        OutboundGroup(
          tag: 'select',
          selected: 'missing',
          items: [OutboundInfo(tag: 'unrelated')],
        ),
      ]).tag,
      isEmpty,
    );
    expect(
      connectedOutbound([
        OutboundGroup(
          tag: 'select',
          items: [OutboundInfo(tag: 'select', isGroup: true)],
        ),
      ]).tag,
      isEmpty,
    );
  });

  Future<void> render(
    WidgetTester tester,
    TestRepository repository, {
    bool connected = true,
    ConnectionStatus? status,
    bool isTv = false,
    double width = 640,
    double textScale = 1,
    int delay = 123,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          connectionNotifierProvider.overrideWith(
            () => TestConnection(status ?? (connected ? const Connected() : const Disconnected())),
          ),
          televisionProvider.overrideWith((ref) => Future.value(isTv)),
          activeProfileProvider.overrideWith(TestProfile.new),
          activeProxyNotifierProvider.overrideWith(() => TestActiveProxy(delay)),
          proxiesOverviewNotifierProvider.overrideWith(TestGroup.new),
          proxyRepositoryProvider.overrideWithValue(repository),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Scaffold(
            body: ListView(padding: EdgeInsets.all(width < 480 ? 12 : 20), children: const [ConnectionControls()]),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('selected ping follows connect button on one row and tests subscription group', (tester) async {
    final repository = TestRepository();
    await render(tester, repository);
    expect(find.text('123 мс'), findsOneWidget);
    final connect = tester.getRect(find.byWidgetPredicate((widget) => widget is FilledButton));
    final ping = tester.getRect(find.byType(OutlinedButton));
    expect(connect.height, 48);
    expect(ping.height, 48);
    expect(connect.top, ping.top);
    expect(ping.left, greaterThan(connect.right));
    await tester.tap(find.byType(OutlinedButton));
    await tester.pump();
    expect(repository.groups, ['subscription-group']);
    expect(find.text('Проверка…'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    expect(repository.groups.length, 1);
    repository.pending.complete(unit);
    await tester.pump();
    expect(find.text('123 мс'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected state never displays stale ping or starts a test', (tester) async {
    final repository = TestRepository();
    await render(tester, repository, connected: false);
    expect(find.text('123 мс'), findsNothing);
    expect(find.text('Пинг'), findsOneWidget);
    await tester.tap(find.byType(OutlinedButton));
    expect(repository.groups, isEmpty);
  });

  testWidgets('compact controls fit narrow screens without overflow', (tester) async {
    await render(tester, TestRepository(), width: 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android controls preserve one row with larger accessibility text', (tester) async {
    await render(tester, TestRepository(), width: 360, textScale: 1.5);
    expect(tester.takeException(), isNull);
    final connect = tester.getRect(find.byWidgetPredicate((widget) => widget is FilledButton));
    final ping = tester.getRect(find.byType(OutlinedButton));
    expect(connect.top, ping.top);
    expect(ping.height, 48);
  });
  testWidgets('connection button is green after successful connection', (tester) async {
    await render(tester, TestRepository());
    final button = tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(button.style!.backgroundColor!.resolve({}), const Color(0xFF16803C));
    expect(button.style!.foregroundColor!.resolve({}), Colors.white);
  });

  testWidgets('unavailable active server is red but disconnect and recheck remain enabled', (tester) async {
    await render(tester, TestRepository(), delay: 65535);
    expect(find.text('Недоступна'), findsOneWidget);
    final button = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(button.style!.backgroundColor!.resolve({}), const Color(0xFFBA1A1A));
    expect(button.onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNotNull);
    expect(find.text('Отключить'), findsOneWidget);
  });

  testWidgets('failed connection is red while ordinary disconnect is neutral', (tester) async {
    await render(tester, TestRepository(), status: const Disconnected(ConnectionFailure.unexpected('test')));
    var button = tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(button.style!.backgroundColor!.resolve({}), const Color(0xFFBA1A1A));
    await tester.pumpWidget(const SizedBox());
    await render(tester, TestRepository(), connected: false);
    button = tester.widget<FilledButton>(find.byWidgetPredicate((widget) => widget is FilledButton));
    expect(button.style!.backgroundColor, isNull);
  });

  testWidgets('TV controls retain compact sizes and connection receives initial focus', (tester) async {
    await render(tester, TestRepository(), isTv: true);
    await tester.pumpAndSettle();
    final connect = find.byWidgetPredicate((widget) => widget is FilledButton);
    expect(tester.getSize(connect).height, 48);
    expect(tester.getSize(find.byType(OutlinedButton)).height, 48);
    expect(tester.widget<FilledButton>(connect).autofocus, isTrue);
  });
}
