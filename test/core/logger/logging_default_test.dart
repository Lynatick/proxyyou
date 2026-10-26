import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/logger/logger_setup.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/log/model/log_level.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart' as logging;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('fresh preferences disable logging; an explicit diagnostic choice survives', () async {
    for (final level in <String?>[null, 'debug', 'off']) {
      SharedPreferences.setMockInitialValues({if (level != null) 'log-level': level});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWith((ref) => Future.value(preferences))],
      );
      await container.read(sharedPreferencesProvider.future);
      expect(container.read(ConfigOptions.logLevel), level == 'debug' ? LogLevel.debug : LogLevel.off);
      container.dispose();
    }
  });

  test('disabled startup creates no file or history, diagnostics can be enabled and disabled', () async {
    final directory = await Directory.systemTemp.createTemp('proxyyou-log-default');
    addTearDown(() async {
      logSetEnabled(false);
      await directory.delete(recursive: true);
    });
    final file = File('${directory.path}/app.log');
    logStart();
    logAddFile(file.path);
    logFinish(keepFile: true);
    logMarkRun('test');
    logging.Logger('test').severe('must not be written');
    await Future<void>.delayed(Duration.zero);
    expect(loggingEnabled, isFalse);
    expect(file.existsSync(), isFalse);
    expect(logRing.records, isEmpty);

    logSetEnabled(true);
    logging.Logger('test').severe('manual diagnostics');
    await Future<void>.delayed(Duration.zero);
    expect(file.readAsStringSync(), contains('manual diagnostics'));
    final size = file.lengthSync();
    logSetEnabled(false);
    logging.Logger('test').severe('disabled again');
    logMarkRun('disabled');
    await Future<void>.delayed(Duration.zero);
    expect(file.lengthSync(), size);
    expect(logRing.records, isEmpty);
  });
}
