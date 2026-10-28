import 'package:flutter/material.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/app_update/notifier/app_update_notifier.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class AppUpdateCard extends ConsumerWidget {
  const AppUpdateCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateNotifierProvider);
    final version = switch (update) {
      AppUpdateStateAvailable(:final versionInfo) || AppUpdateStateIgnored(:final versionInfo) => versionInfo,
      _ => null,
    };
    if (version == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const PlatformIcon(Icons.system_update_alt),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Доступна новая версия', style: Theme.of(context).textTheme.titleMedium),
                        Text('ProxyYou ${version.presentVersion}'),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const PlatformIcon(Icons.download),
                label: const Text('Скачать обновление'),
                onPressed: () async {
                  final launched = await UriUtils.tryLaunch(Uri.parse(Constants.downloadPageUrl));
                  if (!launched && context.mounted) {
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Не удалось открыть страницу загрузки')));
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
