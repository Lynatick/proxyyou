import 'package:flutter/material.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';

abstract final class WindowsIconAssets {
  static const appPng = 'assets/images/windows/app_icon.png';
  static const appIco = 'assets/images/windows/app_icon.ico';

  static String tray(ConnectionStatus status, Brightness brightness, {bool failed = false}) {
    final state = failed || status is Disconnected && status.connectionFailure != null
        ? 'error'
        : switch (status) {
            Connected() => 'connected',
            Connecting() || Disconnecting() => 'busy',
            Disconnected() => 'idle',
          };
    final theme = brightness == Brightness.dark ? 'dark' : 'light';
    return 'assets/images/windows/tray_${state}_$theme.ico';
  }
}
