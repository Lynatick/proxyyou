import 'package:flutter/material.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/profile/notifier/profiles_update_notifier.dart';
import 'package:hiddify/features/profile/notifier/subscription_updates_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class SubscriptionUpdateButton extends ConsumerWidget {
  const SubscriptionUpdateButton({super.key, this.extended = false});
  final bool extended;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final updates = ref.watch(subscriptionUpdatesProvider);
    final updating = ref.watch(subscriptionsUpdatingProvider);
    final profiles = ref.watch(subscriptionProfilesProvider).value;
    final count = updates.available.length;
    final onPressed = updating || profiles == null || profiles.isEmpty
        ? null
        : () => ref.read(foregroundProfilesUpdateNotifierProvider.notifier).trigger();
    final icon = updating
        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2))
        : Badge.count(count: count, isLabelVisible: count > 0, child: const PlatformIcon(Icons.sync));
    if (extended) {
      return FilledButton.icon(
        onPressed: onPressed,
        icon: icon,
        label: const Text('Обновить подписки', maxLines: 1, overflow: TextOverflow.ellipsis),
      );
    }
    return IconButton(
      tooltip: updating
          ? 'Обновляем подписки…'
          : count > 0
          ? 'Есть изменения в подписках: $count. Обновить'
          : 'Обновить подписки',
      onPressed: onPressed,
      icon: icon,
    );
  }
}
