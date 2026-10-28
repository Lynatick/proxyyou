import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/balance_strategy_presentation.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestLeaf extends ActiveProxyNotifier {
  @override
  Stream<OutboundInfo> build() =>
      Stream.value(OutboundInfo(tag: 'b', tagDisplay: 'Сервер Б', type: 'VLESS', urlTestDelay: 87));
}

OutboundGroup selection(String tag) => OutboundGroup(
  tag: 'select',
  selected: tag,
  items: [OutboundInfo(tag: tag, isGroup: tag == 'balance' || tag == 'lowest')],
);

void main() {
  test('strategy labels follow saved preferences on every platform', () async {
    for (final entry in {
      'round-robin': 'Поочерёдно',
      'consistent-hashing': 'Согласованное хеширование',
      'sticky-sessions': 'Закрепление сессий',
    }.entries) {
      SharedPreferences.setMockInitialValues({'balancer-strategy': entry.key});
      final saved = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWith((ref) => Future.value(saved))],
      );
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);
      expect(container.read(balanceStrategyLabelProvider), entry.value);
    }
  });

  testWidgets('balance keeps the strategy visible across server changes and opens the list', (tester) async {
    final groups = StreamController<List<OutboundGroup>>();
    addTearDown(groups.close);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: ActiveProxyFooter()),
        ),
        GoRoute(path: '/proxies', name: 'proxies', builder: (_, _) => const Text('Список конфигураций')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          serviceRunningProvider.overrideWith((ref) => true),
          activeProxyGroupsProvider.overrideWith((ref) => groups.stream),
          balanceStrategyLabelProvider.overrideWith((ref) => 'Поочерёдно'),
          activeProxyNotifierProvider.overrideWith(() => throw StateError('balance must not watch a changing leaf')),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    for (final server in ['Сервер А', 'Сервер Б', 'Сервер А']) {
      groups.add([
        selection('balance'),
        OutboundGroup(
          tag: 'balance',
          selected: server,
          items: [OutboundInfo(tag: server)],
        ),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('balance'), findsOneWidget);
      expect(find.text('Поочерёдно'), findsOneWidget);
      expect(find.text(server), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.tap(find.text('Поочерёдно'));
    await tester.pumpAndSettle();
    expect(find.text('Список конфигураций'), findsOneWidget);
  });

  testWidgets('lowest and manual selection retain the server and protocol', (tester) async {
    for (final mode in ['lowest', 'b']) {
      await tester.pumpWidget(
        ProviderScope(
          key: ValueKey(mode),
          overrides: [
            serviceRunningProvider.overrideWith((ref) => true),
            activeRoutingModeProvider.overrideWith((ref) => mode == 'b' ? null : mode),
            balanceStrategyLabelProvider.overrideWith((ref) => 'Поочерёдно'),
            activeProxyNotifierProvider.overrideWith(TestLeaf.new),
            activeConfigurationNameProvider.overrideWith((ref) => '2. Сервер Б'),
          ],
          child: const MaterialApp(home: Scaffold(body: ActiveProxyFooter())),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2. Сервер Б'), findsOneWidget);
      expect(find.text('VLESS'), findsOneWidget);
      expect(find.text('Поочерёдно'), findsNothing);
    }
  });
}
