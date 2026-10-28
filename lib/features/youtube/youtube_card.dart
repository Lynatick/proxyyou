import 'package:flutter/material.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/youtube/youtube_playback.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class YoutubeCard extends ConsumerWidget {
  const YoutubeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(serviceRunningProvider);
    final enabled = ref.watch(ConfigOptions.enableMixedPort);
    final report = ref.watch(youtubeReportProvider);
    final playbackSupported = ref.watch(youtubePlaybackSupportedProvider);
    final playback = playbackSupported ? ref.watch(youtubePlaybackProvider) : null;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const PlatformIcon(Icons.smart_display_outlined),
                const SizedBox(width: 12),
                Expanded(child: Text('Доступность YouTube', style: theme.textTheme.titleMedium)),
                IconButton(
                  tooltip: 'Проверить ещё раз',
                  onPressed: running && !report.isLoading ? () => ref.invalidate(youtubeReportProvider) : null,
                  icon: const PlatformIcon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!running)
              const Text('Подключитесь к прокси для проверки.')
            else
              report.when(
                loading: () => const Row(
                  children: [
                    SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    SizedBox(width: 12),
                    Expanded(child: Text('Проверяем через соединение…')),
                  ],
                ),
                error: (_, _) => const Text('Не удалось завершить проверку. Попробуйте снова.'),
                data: (value) => value == null
                    ? const SizedBox.shrink()
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (!value.reachable)
                            Text('Конфигурация недоступна', style: TextStyle(color: theme.colorScheme.error)),
                          Text(
                            value.reachable
                                ? 'Предварительная проверка сети пройдена'
                                : value.onlyThumbnailMissing
                                ? 'Тестовая миниатюра недоступна'
                                : 'Предварительная проверка сети не пройдена',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 8),
                          for (final check in value.checks)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Row(
                                children: [
                                  PlatformIcon(
                                    check.reachable ? Icons.check_circle_outline : Icons.info_outline,
                                    size: 18,
                                    color: check.reachable ? Colors.teal : theme.colorScheme.error,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(child: Text('${check.label}: ${_describe(check)}')),
                                ],
                              ),
                            ),
                          if (value.checks.any((check) => check.outcome == ProbeOutcome.tlsFailure)) ...[
                            const SizedBox(height: 8),
                            Text(
                              'Не удалось установить защищённое соединение через выбранный сервер. '
                              '${playbackSupported ? 'Попробуйте другой сервер или проверку воспроизведения ниже. ' : 'Попробуйте другой сервер. '}'
                              'Сетевая проверка не подтверждает воспроизведение видео.',
                            ),
                          ],
                          Text(
                            'Проверено в ${TimeOfDay.fromDateTime(value.checkedAt).format(context)}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
              ),
            if (playback != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: running && enabled && playback.status != PlaybackStatus.checking
                    ? () => ref.read(youtubePlaybackProvider.notifier).start()
                    : null,
                icon: const PlatformIcon(Icons.play_arrow),
                label: const Text('Проверить воспроизведение'),
              ),
              const SizedBox(height: 8),
              Text(switch (playback.status) {
                PlaybackStatus.passed =>
                  'Воспроизведение подтверждено: ${playback.seconds.toStringAsFixed(1)} с, ${playback.frames} кадров',
                PlaybackStatus.checking => 'Нажмите Play в открывшемся плеере. Проверяем реальные кадры…',
                PlaybackStatus.failed => 'Воспроизведение не подтверждено. Повторите проверку.',
                PlaybackStatus.unsupported => 'Для проверки нужен поддерживаемый видеоплеер.',
                PlaybackStatus.cancelled => 'Проверка отменена.',
                PlaybackStatus.idle => 'Успех требует минимум 5 секунд воспроизведения с декодированными кадрами.',
              }),
              const SizedBox(height: 12),
              Text(
                'Проверяется тестовое видео. Результат относится к текущему соединению; другие видео могут иметь ограничения.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _describe(ProbeResult check) => switch (check.outcome) {
    ProbeOutcome.reachable => '${check.elapsed.inMilliseconds} мс',
    ProbeOutcome.rejected when check.missingThumbnail => 'тестовая миниатюра не найдена (HTTP 404)',
    ProbeOutcome.rejected => 'HTTP ${check.statusCode}',
    ProbeOutcome.unexpectedResponse => 'неожиданный ответ',
    ProbeOutcome.timeout => 'превышено время ожидания',
    ProbeOutcome.tlsFailure => switch (check.tlsReason) {
      TlsFailureReason.certificateExpired => 'срок сертификата истёк — проверьте дату и время',
      TlsFailureReason.hostnameMismatch => 'сертификат выдан для другого сайта',
      TlsFailureReason.untrustedCertificate => 'сертификат не прошёл проверку доверия',
      TlsFailureReason.connectionClosed => 'соединение оборвано во время TLS-подключения',
      _ => 'не удалось установить TLS-соединение',
    },
    ProbeOutcome.networkFailure => 'ошибка сети или прокси',
  };
}
