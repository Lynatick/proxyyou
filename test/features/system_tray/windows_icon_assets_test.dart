import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/widget/windows_icon_assets.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';

void main() {
  test('tray states and themes have different, existing Windows resources', () {
    final paths = <String>{};
    for (final brightness in Brightness.values) {
      for (final status in [
        const Connected(),
        const Connecting(),
        const Disconnected(),
        const Disconnected(ConnectionFailure.unexpected('test')),
      ]) {
        final path = WindowsIconAssets.tray(status, brightness);
        expect(paths.add(path), isTrue);
        expect(File(path).existsSync(), isTrue);
      }
      expect(
        WindowsIconAssets.tray(const Connecting(), brightness),
        WindowsIconAssets.tray(const Disconnecting(), brightness),
      );
      expect(
        WindowsIconAssets.tray(const Connected(), brightness, failed: true),
        WindowsIconAssets.tray(const Disconnected(ConnectionFailure.unexpected('test')), brightness),
      );
    }
    expect(paths, hasLength(8));
  });

  test('ICO frames include native 16, 20, 24, 32, 40, 48, 64 pixel sizes', () {
    for (final file in Directory(
      'assets/images/windows',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.ico'))) {
      final bytes = file.readAsBytesSync();
      final data = ByteData.sublistView(bytes);
      expect(data.getUint16(0, Endian.little), 0);
      expect(data.getUint16(2, Endian.little), 1);
      final count = data.getUint16(4, Endian.little);
      final sizes = <int>{};
      for (var i = 0; i < count; i++) {
        final offset = 6 + i * 16;
        sizes.add(bytes[offset] == 0 ? 256 : bytes[offset]);
        final length = data.getUint32(offset + 8, Endian.little);
        final start = data.getUint32(offset + 12, Endian.little);
        expect(start + length, lessThanOrEqualTo(bytes.length));
        expect(bytes.sublist(start, start + 8), [137, 80, 78, 71, 13, 10, 26, 10]);
        expect(data.getUint16(offset + 6, Endian.little), 32);
      }
      expect(sizes, containsAll([16, 20, 24, 32, 40, 48, 64]));
      if (file.path.endsWith('app_icon.ico')) expect(sizes, containsAll([96, 128, 256]));
    }
    expect(
      File('windows/runner/resources/app_icon.ico').readAsBytesSync(),
      File(WindowsIconAssets.appIco).readAsBytesSync(),
    );
  });
}
