import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/proxy/active/active_proxy_notifier.dart';
import 'package:hiddify/features/proxy/active/balance_strategy_presentation.dart';
import 'package:hiddify/features/proxy/data/configuration_catalog.dart';
import 'package:hiddify/hiddifycore/generated/v2/hcore/hcore.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final activeConfigurationNameProvider = FutureProvider.autoDispose<String?>((ref) {
  final tag = ref.watch(activeProxyNotifierProvider.select((value) => value.value?.tag));
  final profile = ref.watch(activeProfileProvider.select((value) => value.value?.id));
  final running = ref.watch(serviceRunningProvider);
  if (!running || tag == null || tag.isEmpty || profile == null) return null;
  return ref.watch(configurationCatalogProvider).numberedName(profile, tag, connected: true);
});

class ActiveProxyFooter extends ConsumerWidget {
  const ActiveProxyFooter({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(serviceRunningProvider);
    if (!running) return const SizedBox.shrink();
    final mode = ref.watch(activeRoutingModeProvider);
    final strategy = mode == 'balance' ? ref.watch(balanceStrategyLabelProvider) : null;
    if (strategy != null) {
      return ConnectedConfigurationButton(
        name: strategy,
        protocol: '',
        mode: mode,
        onPressed: () => context.goNamed('proxies'),
      );
    }
    final active = ref.watch(activeProxyNotifierProvider).value;
    if (active == null) return const SizedBox.shrink();
    return ConnectedConfigurationButton(
      name: ref.watch(activeConfigurationNameProvider).value ?? active.tagDisplay,
      protocol: active.type,
      mode: mode,
      onPressed: () => context.goNamed('proxies'),
    );
  }
}

class ConnectedConfigurationButton extends StatelessWidget {
  const ConnectedConfigurationButton({
    super.key,
    required this.name,
    required this.protocol,
    required this.onPressed,
    this.mode,
  });
  final String name;
  final String protocol;
  final String? mode;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              const PlatformIcon(Icons.route_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (mode == 'balance' || mode == 'lowest') ...[
                      Text(
                        mode!,
                        key: const ValueKey('connected-routing-mode'),
                        style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
                      ),
                      const SizedBox(height: 4),
                    ],
                    Text(
                      name.isEmpty ? 'Сервер ещё не выбран' : name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (protocol.isNotEmpty) Text(protocol, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const PlatformIcon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

String getRealOutboundTag(OutboundInfo group) {
  var tag = group.tagDisplay;
  if (group.groupSelectedTagDisplay.isNotEmpty && group.groupSelectedTagDisplay != tag) {
    tag = '$tag → ${group.groupSelectedTagDisplay}';
  }
  return tag;
}
