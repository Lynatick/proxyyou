import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

// A balancer uses several servers, so its card describes the routing strategy.
// Traffic selection and the most recently used server's ping stay in the core.
final balanceStrategyLabelProvider = Provider<String>((ref) {
  return switch (ref.watch(ConfigOptions.balancerStrategy)) {
    BalancerStrategy.roundRobin => 'Поочерёдно',
    BalancerStrategy.consistentHash => 'Согласованное хеширование',
    BalancerStrategy.stickySession => 'Закрепление сессий',
  };
});
