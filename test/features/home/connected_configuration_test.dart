import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/features/proxy/active/active_proxy_card.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/widget/proxy_tile.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

void main() {
  testWidgets('long configuration names stay on one line in the grid and connected button', (tester) async {
    final name = '12345. ${List.filled(30, 'Длинное название сервера').join(' ')}';
    final translations = (await tester.runAsync(() => AppLocale.ru.build()))!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [translationsProvider.overrideWithValue(AsyncData(translations))],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              child: Column(
                children: [
                  ProxyTile(
                    OutboundInfo(tag: 'server', tagDisplay: name, type: 'VLESS'),
                    selected: false,
                    onTap: () {},
                  ),
                  ConnectedConfigurationButton(name: name, protocol: 'VLESS', onPressed: () {}),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    for (final text in tester.widgetList<Text>(find.text(name))) {
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
    }
    expect(find.text(name), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  test('mode comes only from the selected automatic group', () {
    for (final mode in ['balance', 'lowest']) {
      expect(
        connectedRoutingMode([
          OutboundGroup(
            tag: 'select',
            selected: mode,
            items: [OutboundInfo(tag: mode, isGroup: true)],
          ),
        ]),
        mode,
      );
    }
    expect(
      connectedRoutingMode([
        OutboundGroup(
          tag: 'select',
          selected: 'server-lowest',
          items: [OutboundInfo(tag: 'server-lowest')],
        ),
      ]),
      isNull,
    );
    expect(
      connectedRoutingMode([
        OutboundGroup(
          tag: 'select',
          selected: 'balance',
          items: [OutboundInfo(tag: 'balance')],
        ),
      ]),
      isNull,
    );
    expect(connectedRoutingMode([]), isNull);
  });
  testWidgets('connected card shows mode above name with no IP details', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectedConfigurationButton(name: 'Сервер', protocol: 'VLESS', mode: 'lowest', onPressed: () {}),
        ),
      ),
    );
    expect(find.text('lowest'), findsOneWidget);
    expect(tester.widget<Text>(find.text('Сервер')).maxLines, 1);
    expect(tester.widget<Text>(find.text('Сервер')).overflow, TextOverflow.ellipsis);
    expect(tester.getTopLeft(find.text('lowest')).dy, lessThan(tester.getTopLeft(find.text('Сервер')).dy));
    expect(find.textContaining('IP'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectedConfigurationButton(name: 'Другой сервер', protocol: 'VLESS', onPressed: () {}),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('connected-routing-mode')), findsNothing);
  });
  test('manual and automatic round trips preserve the actual leaf and its ping', () {
    for (final mode in ['server-a', 'balance', 'server-a', 'lowest', 'server-b']) {
      final automatic = mode == 'balance' || mode == 'lowest';
      final leaf = automatic ? 'server-b' : mode;
      final groups = [
        OutboundGroup(
          tag: 'select',
          selected: mode,
          items: [OutboundInfo(tag: mode, isGroup: automatic, urlTestDelay: 4)],
        ),
        OutboundGroup(
          tag: 'balance',
          selected: 'server-b',
          items: [OutboundInfo(tag: 'server-b', urlTestDelay: 87)],
        ),
        OutboundGroup(
          tag: 'lowest',
          selected: 'server-b',
          items: [OutboundInfo(tag: 'server-b', urlTestDelay: 87)],
        ),
      ];
      final selected = connectedOutbound(groups);
      expect(selected.tag, leaf);
      expect(selected.urlTestDelay, automatic ? 87 : 4);
      expect(connectedRoutingMode(groups), automatic ? mode : null);
    }
  });
  testWidgets('cold automatic group shows an honest placeholder and stays clickable', (tester) async {
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ConnectedConfigurationButton(name: '', protocol: '', mode: 'balance', onPressed: () => opened = true),
        ),
      ),
    );
    await tester.tap(find.text('Сервер ещё не выбран'));
    expect(opened, isTrue);
  });
}
