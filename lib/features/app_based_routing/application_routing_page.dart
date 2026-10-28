import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/app_based_routing/mac_app_preferences.dart';
import 'package:hiddify/features/app_based_routing/model/per_app_proxy_mode.dart';
import 'package:hiddify/features/app_based_routing/overview/app_list_page.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/notifier/active_profile_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/settings/overview/sections/routing_options_page.dart';
import 'package:hiddify/singbox/model/singbox_config_enum.dart';
import 'package:hiddify/utils/platform_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

final macApplicationsProvider = FutureProvider<List<Map<String, dynamic>>>((ref) async {
  final result = await const MethodChannel('dev.proxyyou/applications').invokeListMethod<dynamic>('list');
  return (result ?? []).map((item) => Map<String, dynamic>.from(item as Map)).toList();
});

class ApplicationRoutingPage extends HookConsumerWidget {
  const ApplicationRoutingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mac = PlatformUtils.isMacOS;
    final enabled = useState(ref.read(MacAppPreferences.enabled));
    final mode = useState(ref.read(MacAppPreferences.mode));
    final selected = useState(ref.read(MacAppPreferences.bundles).toSet());
    final search = useState('');
    final saving = useState(false);
    final connection = ref.watch(connectionNotifierProvider);
    final switching = connection.isLoading || (connection.value?.isSwitching ?? false);
    final serviceMode = ref.watch(ConfigOptions.serviceMode);
    final applications = mac ? ref.watch(macApplicationsProvider) : null;

    Future<void> apply() async {
      if (saving.value || switching) return;
      final filterEnabled = mac ? enabled.value : ref.read(Preferences.perAppProxyEnabled);
      if (filterEnabled && serviceMode != (mac ? ServiceMode.systemProxy : ServiceMode.tun)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              mac ? 'Для выбора программ включите системный прокси.' : 'Для выбора программ включите режим VPN.',
            ),
          ),
        );
        return;
      }
      if (!mac &&
          filterEnabled &&
          ref.read(Preferences.perAppProxyMode) == AppProxyMode.include &&
          ref.read(Preferences.includeApps).where((app) => app.trim().isNotEmpty).isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Выберите хотя бы одну программу.')));
        return;
      }
      if (mac && enabled.value && mode.value == 'include' && selected.value.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Выберите хотя бы одну программу.')));
        return;
      }
      saving.value = true;
      try {
        if (mac) {
          await ref.read(MacAppPreferences.bundles.notifier).update(selected.value.toList()..sort());
          await ref.read(MacAppPreferences.mode.notifier).update(mode.value);
          await ref.read(MacAppPreferences.enabled.notifier).update(enabled.value);
        }
        if (connection.value?.isConnected ?? false) {
          final profile = await ref.read(activeProfileProvider.future);
          if (profile != null) {
            final repository = ref.read(connectionRepositoryProvider);
            await repository.disconnect().getOrElse((error) => throw error).run();
            await repository
                .connect(profile, ref.read(Preferences.disableMemoryLimit))
                .getOrElse((error) => throw error)
                .run();
          }
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Настройки программ применены.')));
        }
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Не удалось применить настройки: $error')));
        }
      } finally {
        if (context.mounted) saving.value = false;
      }
    }

    final filtered =
        applications?.value?.where((app) {
          final query = search.value.toLowerCase();
          return '${app['name']} ${app['path']}'.toLowerCase().contains(query);
        }).toList() ??
        [];
    return Scaffold(
      appBar: AppBar(title: const Text('Проксирование программ')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                Text(
                  mac
                      ? 'macOS: фильтр действует для соединений через системный прокси. Программы, игнорирующие его, не перехватываются. Неопределённые и общие системные сетевые процессы идут напрямую.'
                      : 'Android: выбор программ работает в режиме VPN. После изменения списка нажмите «Применить», чтобы пересоздать VPN-подключение.',
                ),
                if (serviceMode != (mac ? ServiceMode.systemProxy : ServiceMode.tun))
                  TextButton.icon(
                    onPressed: switching || (connection.value?.isConnected ?? false)
                        ? null
                        : () => ref
                              .read(ConfigOptions.serviceMode.notifier)
                              .update(mac ? ServiceMode.systemProxy : ServiceMode.tun),
                    icon: const PlatformIcon(Icons.settings_ethernet),
                    label: Text(mac ? 'Включить системный прокси' : 'Включить режим VPN'),
                  ),
                if (mac) ...[
                  SwitchListTile(
                    title: const Text('Использовать выбор программ'),
                    value: enabled.value,
                    onChanged: saving.value ? null : (value) => enabled.value = value,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: mode.value,
                    items: const [
                      DropdownMenuItem(value: 'include', child: Text('Проксировать только выбранные')),
                      DropdownMenuItem(value: 'exclude', child: Text('Исключить выбранные из прокси')),
                    ],
                    onChanged: saving.value ? null : (value) => mode.value = value ?? 'include',
                  ),
                  TextField(
                    decoration: const InputDecoration(labelText: 'Поиск программы'),
                    onChanged: (value) => search.value = value,
                  ),
                  Align(alignment: Alignment.centerLeft, child: Text('Выбрано: ${selected.value.length}')),
                ],
              ],
            ),
          ),
          Expanded(
            child: mac
                ? applications!.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (_, _) => Center(
                      child: TextButton(
                        onPressed: () => ref.invalidate(macApplicationsProvider),
                        child: const Text('Повторить загрузку программ'),
                      ),
                    ),
                    data: (_) => ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final app = filtered[index];
                        final path = app['path'] as String;
                        final supported = app['supported'] != false;
                        return CheckboxListTile(
                          title: Text(app['name'] as String),
                          subtitle: Text(supported ? path : 'Общий сетевой процесс macOS — выбор пока недоступен'),
                          value: selected.value.contains(path),
                          onChanged: !enabled.value || saving.value || !supported
                              ? null
                              : (value) {
                                  final updated = {...selected.value};
                                  if (value ?? false) {
                                    updated.add(path);
                                  } else {
                                    updated.remove(path);
                                  }
                                  selected.value = updated;
                                },
                        );
                      },
                    ),
                  )
                : SingleChildScrollView(
                    child: AppBasedRoutingSection(
                      onChooseApps: () =>
                          Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AppListPage())),
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: saving.value || switching ? null : apply,
              icon: const PlatformIcon(Icons.check),
              label: Text(saving.value ? 'Применение…' : 'Применить'),
            ),
          ),
        ],
      ),
    );
  }
}
