import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/data/proxy_data_providers.dart';
import 'package:hiddify/features/tv/tv_mode.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class ConnectionControls extends ConsumerStatefulWidget {
  const ConnectionControls({super.key});

  @override
  ConsumerState<ConnectionControls> createState() => _ConnectionControlsState();
}

class _ConnectionControlsState extends ConsumerState<ConnectionControls> {
  bool _testing = false;

  Future<void> _testSubscription() async {
    setState(() => _testing = true);
    try {
      final repository = ref.read(proxyRepositoryProvider);
      final snapshot = await repository.watchProxies().first.timeout(const Duration(seconds: 10));
      final group = snapshot.getOrElse((error) => throw error);
      final groupTag = group?.tag.isNotEmpty == true ? group!.tag : 'select';
      await repository.urlTest(groupTag).getOrElse((error) => throw error).run();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Не удалось проверить задержки. Повторите после подключения.')));
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(activeProfileProvider).value;
    final connection = ref.watch(connectionNotifierProvider);
    final isTv = ref.watch(televisionProvider).value ?? false;
    final failed =
        connection.hasError ||
        switch (connection.value) {
          Disconnected(connectionFailure: final _?) => true,
          _ => false,
        };
    final running = connection.value?.isConnected ?? false;
    final active = ref.watch(activeProxyNotifierProvider).value;
    final delay = active?.urlTestDelay ?? 0;
    final unavailable = running && delay != 0 && !ConnectionConst.isValidDelay(delay);
    final busy = connection.isLoading || (connection.value?.isSwitching ?? false);
    final buttonColor = busy
        ? null
        : failed || unavailable
        ? const Color(0xFFBA1A1A)
        : running
        ? const Color(0xFF16803C)
        : null;
    final ping = !running
        ? 'Пинг'
        : delay == 0
        ? '— мс'
        : ConnectionConst.isValidDelay(delay)
        ? '$delay мс'
        : 'Недоступна';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 340;
            return Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: FilledButton.icon(
                      autofocus: isTv,
                      onPressed: busy || (profile == null && !running)
                          ? null
                          : () => ref.read(connectionNotifierProvider.notifier).toggleConnection(),
                      style: FilledButton.styleFrom(
                        backgroundColor: buttonColor,
                        foregroundColor: buttonColor == null ? null : Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                      ),
                      icon: PlatformIcon(running ? Icons.shield_outlined : Icons.power_settings_new, size: 22),
                      label: Text(
                        busy
                            ? 'Подождите…'
                            : running
                            ? 'Отключить'
                            : 'Подключить',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                SizedBox(width: compact ? 8 : 12),
                Tooltip(
                  message: 'Проверить задержки всех серверов текущей подписки',
                  child: SizedBox(
                    height: 48,
                    width: compact ? 108 : 132,
                    child: OutlinedButton.icon(
                      onPressed: running && !busy && !_testing && profile != null ? _testSubscription : null,
                      style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                      icon: _testing
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const PlatformIcon(Icons.network_check, size: 20),
                      label: Text(
                        _testing ? (compact ? '…' : 'Проверка…') : ping,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: compact ? const TextStyle(fontSize: 12) : null,
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
