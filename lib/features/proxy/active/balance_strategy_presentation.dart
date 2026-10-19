import 'dart:ffi';

import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// Trial presentation for the Apple Silicon build only. Traffic selection and
// the ping of the most recently used server remain owned by the native core.
final siliconBalanceStrategyProvider = Provider<String?>((ref) {
  if (Abi.current() != Abi.macosArm64) return null;
  return switch (ref.watch(ConfigOptions.balancerStrategy)) {
    BalancerStrategy.roundRobin => 'Поочерёдно',
    BalancerStrategy.consistentHash => 'Согласованное хеширование',
    BalancerStrategy.stickySession => 'Закрепление сессий',
  };
});
