import 'package:flutter/material.dart';
import 'package:hiddify/core/widget/platform_icon.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/youtube/youtube_playback.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';
import 'package:hiddify/features/youtube/youtube_test_video.dart';
import 'package:hiddify/utils/uri_utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

class YoutubeCard extends ConsumerWidget {
  const YoutubeCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(serviceRunningProvider);
    final enabled = ref.watch(ConfigOptions.enableMixedPort);
    // Watching the report starts a check on connection/route changes; no tap is required.
    final report = ref.watch(youtubeReportProvider);
    final thumbnail = ref.watch(youtubeThumbnailProvider).value;
    final playbackSupported = ref.watch(youtubePlaybackSupportedProvider);
    final playback = playbackSupported ? ref.watch(youtubePlaybackProvider) : null;
    final theme = Theme.of(context);
    final status = !running
        ? 'Нет подключения'
        : report.isLoading
        ? 'Проверяем доступность…'
        : report.hasError
        ? 'Не удалось завершить проверку'
        : report.value == null
        ? 'Ожидаем конфигурацию…'
        : '${report.value!.reachable ? 'Сеть доступна' : 'Конфигурация недоступна'} · '
              '${report.value!.checks.map((check) => '${check.label}: ${_describe(check)}').join(' · ')}';
    final playbackResult = switch (playback?.status) {
      PlaybackStatus.passed =>
        'Воспроизведение подтверждено: ${playback!.seconds.toStringAsFixed(1)} с, ${playback.frames} кадров',
      PlaybackStatus.checking => 'Проверяем воспроизведение…',
      PlaybackStatus.failed => 'Воспроизведение не подтверждено',
      PlaybackStatus.unsupported => 'Воспроизведение не поддерживается',
      PlaybackStatus.cancelled => 'Проверка воспроизведения отменена',
      _ => null,
    };
    final result = playbackResult == null ? status : '$status · $playbackResult';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: 'Тестовое видео',
                    child: TextButton.icon(
                      onPressed:
                          running && (!playbackSupported || enabled) && playback?.status != PlaybackStatus.checking
                          ? () async {
                              if (playbackSupported) {
                                await ref.read(youtubePlaybackProvider.notifier).start();
                              } else {
                                // Windows opens the video without initializing a playback checker.
                                await UriUtils.tryLaunch(
                                  Uri.parse('https://www.youtube.com/watch?v=$youtubeTestVideoId'),
                                );
                              }
                            }
                          : null,
                      icon: const PlatformIcon(Icons.smart_display_outlined),
                      label: const Text('Доступность YouTube', maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Проверить ещё раз',
                  onPressed: running && !report.isLoading ? () => ref.invalidate(youtubeReportProvider) : null,
                  icon: const PlatformIcon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                key: const ValueKey('youtube-thumbnail'),
                height: 160,
                child: thumbnail == null
                    ? ColoredBox(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Center(child: PlatformIcon(Icons.smart_display_outlined, size: 48)),
                      )
                    : Image.memory(
                        thumbnail,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) =>
                            const Center(child: PlatformIcon(Icons.smart_display_outlined, size: 48)),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Tooltip(
              message: result,
              child: Text(
                result,
                key: const ValueKey('youtube-availability-result'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color:
                      running &&
                          (report.hasError ||
                              report.value?.reachable == false ||
                              playback?.status == PlaybackStatus.failed)
                      ? theme.colorScheme.error
                      : null,
                ),
              ),
            ),
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
