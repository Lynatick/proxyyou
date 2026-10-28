import 'package:flutter/material.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/widget/windows_icon_assets.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/window/notifier/window_notifier.dart';
import 'package:hiddify/gen/assets.gen.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

part 'system_tray_notifier.g.dart';

@Riverpod(keepAlive: true)
class SystemTrayNotifier extends _$SystemTrayNotifier with TrayListener, WidgetsBindingObserver, AppLogger {
  bool listenerAdded = false;
  int _updateRevision = 0;
  Future<void> _pendingUpdate = Future.value();
  ({String path, bool isTemplate})? _currentIcon;

  @override
  Future<void> build() {
    assert(PlatformUtils.isDesktop);
    if (!listenerAdded) {
      trayManager.addListener(this);
      if (PlatformUtils.isWindows) WidgetsBinding.instance.addObserver(this);
      listenerAdded = true;
      ref.onDispose(() {
        trayManager.removeListener(this);
        if (PlatformUtils.isWindows) WidgetsBinding.instance.removeObserver(this);
        listenerAdded = false;
        _updateRevision++;
      });
    }

    // A ping may arrive late or never arrive. The core's connection status is
    // sufficient to update the icon and keep Disconnect available in the menu.
    final t = ref.watch(translationsProvider).value;
    final connectionState = ref.watch(connectionNotifierProvider);
    final connection = connectionState.hasError
        ? const ConnectionStatus.disconnected()
        : connectionState.value ?? const ConnectionStatus.disconnected();
    final urlTestDelay = ref.watch(activeProxyNotifierProvider).asData?.value.urlTestDelay ?? 0;
    final serviceMode = ref.watch(ConfigOptions.serviceMode);
    final revision = ++_updateRevision;
    final icon = (
      path: _trayIconPath(connection, failed: connectionState.hasError),
      // macOS templates discard the green pixels of the connected icon.
      isTemplate: PlatformUtils.isMacOS && !connection.isConnected,
    );

    // Asset loading and native calls are asynchronous. Serialize them so that a
    // slow update cannot restore an old icon after a quick connect/disconnect.
    final update = _pendingUpdate.then((_) async {
      if (revision != _updateRevision) return;
      if (_currentIcon != icon) {
        await trayManager.setIcon(icon.path, isTemplate: icon.isTemplate);
        _currentIcon = icon;
      }
      if (revision != _updateRevision || t == null) return;
      if (!PlatformUtils.isLinux) await trayManager.setToolTip(_trayTooltip(connection, urlTestDelay, t));
      if (revision != _updateRevision) return;
      await trayManager.setContextMenu(_trayMenu(connection, serviceMode, t));
    });
    // A failed platform call must not prevent subsequent status updates.
    _pendingUpdate = update.onError((error, stackTrace) {
      loggy.warning("error updating system tray", error, stackTrace);
    });
    return update;
  }

  Menu _trayMenu(ConnectionStatus connection, ServiceMode serviceMode, Translations t) => Menu(
    items: [
      if (PlatformUtils.isLinux) ...[MenuItem(key: 'dashboard', label: t.common.dashboard), MenuItem.separator()],
      MenuItem(
        key: 'connection',
        label: switch (connection) {
          Disconnected() => t.connection.connect,
          Connecting() => t.connection.connecting,
          Connected() => t.connection.disconnect,
          Disconnecting() => t.connection.disconnecting,
        },
        disabled: connection.isSwitching,
      ),
      MenuItem.submenu(
        label: t.pages.settings.inbound.serviceMode,
        icon: PlatformUtils.isWindows ? WindowsIconAssets.appIco : Assets.images.trayIconIco,
        submenu: Menu(
          items: [
            ...ServiceMode.values.map(
              (e) => MenuItem.checkbox(checked: e == serviceMode, key: e.name, label: e.present(t)),
            ),
          ],
        ),
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: t.common.quit),
    ],
  );

  @override
  void didChangePlatformBrightness() {
    if (ref.mounted && PlatformUtils.isWindows) ref.invalidateSelf();
  }

  String _trayIconPath(ConnectionStatus status, {bool failed = false}) {
    final brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    if (PlatformUtils.isWindows) return WindowsIconAssets.tray(status, brightness, failed: failed);
    const images = Assets.images;
    return switch (status) {
      Connected() => images.trayIconConnectedPng.path,
      Connecting() || Disconnecting() => images.trayIconDisconnectedPng.path,
      Disconnected() => brightness == Brightness.dark ? images.trayIconDarkPng.path : images.trayIconPng.path,
    };
  }

  String _trayTooltip(ConnectionStatus connection, int urlTestDelay, Translations t) {
    final r = "${Constants.appName} - ${connection.present(t)}";
    final hasDelay = connection.isConnected && ConnectionConst.isValidDelay(urlTestDelay);
    if (PlatformUtils.isMacOS) windowManager.setBadgeLabel(hasDelay ? "$urlTestDelay мс" : "");
    return hasDelay ? '$r: $urlTestDelay мс' : r;
  }

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    // if (menuItem.key == 'dashboard') {
    //   await ref.read(windowNotifierProvider.notifier).open();
    // }
    if (menuItem.key == 'dashboard') {
      await ref.read(windowNotifierProvider.notifier).show();
    } else if (menuItem.key == 'connection') {
      await ref.read(connectionNotifierProvider.notifier).toggleConnection();
    } else if (menuItem.key == 'quit') {
      await ref.read(windowNotifierProvider.notifier).exit();
    } else {
      final newMode = ServiceMode.values.byName(menuItem.key!);
      loggy.debug("switching service mode: [$newMode]");
      await ref.read(ConfigOptions.serviceMode.notifier).update(newMode);
    }
  }

  @override
  Future<void> onTrayIconMouseDown() async {
    // if (Platform.isMacOS) {
    //   await trayManager.popUpContextMenu();
    // } else {
    //   await ref.read(windowNotifierProvider.notifier).hideOrShow();
    // }
    await ref.read(windowNotifierProvider.notifier).showOrHide();
  }

  @override
  Future<void> onTrayIconRightMouseDown() async {
    await trayManager.popUpContextMenu();
  }
}

// @Riverpod(keepAlive: true)
// class SystemTrayNotifier extends _$SystemTrayNotifier with AppLogger {
//   @override
//   Future<void> build() async {
//     if (!PlatformUtils.isDesktop) return;

//     final activeProxy = await ref.watch(activeProxyNotifierProvider.future);
//     final delay = activeProxy.urlTestDelay;
//     final newConnectionStatus = delay > 0 && delay < 65000;
//     ConnectionStatus connection;
//     try {
//       connection = await ref.watch(connectionNotifierProvider.future);
//     } catch (e) {
//       loggy.warning("error getting connection status", e);
//       connection = const ConnectionStatus.disconnected();
//     }

//     final t = await ref.watch(translationsProvider.future);

//     var tooltip = Constants.appName;
//     final serviceMode = ref.watch(ConfigOptions.serviceMode);
//     if (connection is Disconnected) {
//       setIcon(connection);
//     } else if (newConnectionStatus) {
//       setIcon(const Connected());
//       tooltip = "$tooltip - ${connection.present(t)}";
//       if (newConnectionStatus) {
//         tooltip = "$tooltip : ${delay}ms";
//       } else {
//         tooltip = "$tooltip : -";
//       }
//       // else if (delay>1000)
//       //   SystemTrayNotifier.setIcon(timeout ? Disconnecting() : Connecting());
//     } else {
//       setIcon(const Disconnecting());
//       tooltip = "$tooltip - ${connection.present(t)}";
//     }
//     if (Platform.isMacOS) {
//       windowManager.setBadgeLabel("${delay}ms");
//     }
//     if (!Platform.isLinux) await trayManager.setToolTip(tooltip);

//     // final destinations = <(String label, String location)>[
//     //   (t.home.pageTitle, const HomeRoute().location),
//     //   (t.proxies.pageTitle, const ProfilesOverviewRoute().location),
//     //   (t.logs.title, const LogsOverviewRoute().location),
//     //   // (t.settings.pageTitle, const SettingsRoute().location),
//     //   (t.about.pageTitle, const AboutRoute().location),
//     // ];

//     // loggy.debug('updating system tray');

//     final menu = Menu(
//       items: [
//         MenuItem(
//           label: t.tray.dashboard,
//           onClick: (_) async {
//             await ref.read(windowNotifierProvider.notifier).open();
//           },
//         ),
//         MenuItem.separator(),
//         MenuItem.checkbox(
//           label: switch (connection) {
//             Disconnected() => t.tray.status.connect,
//             Connecting() => t.tray.status.connecting,
//             Connected() => t.tray.status.disconnect,
//             Disconnecting() => t.tray.status.disconnecting,
//           },
//           // checked: connection.isConnected,
//           checked: false,
//           disabled: connection.isSwitching,
//           onClick: (_) async {
//            await ref.read(connectionNotifierProvider.notifier).toggleConnection();
//          },
//        ),
//         MenuItem.separator(),
//         MenuItem(
//           label: t.config.serviceMode,
//           icon: Assets.images.trayIconIco,
//           disabled: true,
//         ),

//         ...ServiceMode.values.map(
//           (e) => MenuItem.checkbox(
//             checked: e == serviceMode,
//             key: e.name,
//             label: e.present(t),
//             onClick: (menuItem) async {
//               final newMode = ServiceMode.values.byName(menuItem.key!);
//               loggy.debug("switching service mode: [$newMode]");
//               await ref.read(ConfigOptions.serviceMode.notifier).update(newMode);
//             },
//           ),
//         ),

//         // MenuItem.submenu(
//         //   label: t.tray.open,
//         //   submenu: Menu(
//         //     items: [
//         //       ...destinations.map(
//         //         (e) => MenuItem(
//         //           label: e.$1,
//         //           onClick: (_) async {
//         //             await ref.read(windowNotifierProvider.notifier).open();
//         //             ref.read(routerProvider).go(e.$2);
//         //           },
//         //         ),
//         //       ),
//         //     ],
//         //   ),
//         // ),
//         MenuItem.separator(),
//         MenuItem(
//           label: t.tray.quit,
//           onClick: (_) async {
//             return ref.read(windowNotifierProvider.notifier).quit();
//           },
//         ),
//       ],
//     );

//     await trayManager.setContextMenu(menu);
//   }

//   static void setIcon(ConnectionStatus status) {
//     if (!PlatformUtils.isDesktop) return;
//     trayManager
//         .setIcon(
//           _trayIconPath(status),
//           isTemplate: Platform.isMacOS,
//         )
//         .asStream();
//   }

//   static String _trayIconPath(ConnectionStatus status) {
//     if (Platform.isWindows) {
//       final Brightness brightness = WidgetsBinding.instance.platformDispatcher.platformBrightness;
//       final isDarkMode = brightness == Brightness.dark;
//       switch (status) {
//         case Connected():
//           return Assets.images.trayIconConnectedIco;
//         case Connecting():
//           return Assets.images.trayIconDisconnectedIco;
//         case Disconnecting():
//           return Assets.images.trayIconDisconnectedIco;
//         case Disconnected():
//           if (isDarkMode) {
//             return Assets.images.trayIconIco;
//           } else {
//             return Assets.images.trayIconDarkIco;
//           }
//       }
//     }
//     // const isDarkMode = false;
//     switch (status) {
//       case Connected():
//         return Assets.images.trayIconConnectedPng.path;
//       case Connecting():
//         return Assets.images.trayIconDisconnectedPng.path;
//       case Disconnecting():
//         return Assets.images.trayIconDisconnectedPng.path;
//       case Disconnected():
//         // if (isDarkMode) {
//         //   return Assets.images.trayIconDarkPng.path;
//         // } else {
//         //   return Assets.images.trayIconPng.path;
//         // }
//         return Assets.images.trayIconPng.path;
//     }
//     // return Assets.images.trayIconPng.path;
//   }
// }
