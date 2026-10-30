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
    final playbackSupported = ref.watch(youtubePlaybackSupportedProvider);
    final playback = playbackSupported ? ref.watch(youtubePlaybackProvider) : null;
    ProbeResult? check(bool thumbnail) {
      for (final item in report.value?.checks ?? const <ProbeResult>[]) {
        if (item.isThumbnail == thumbnail) return item;
      }
      return null;
    }

    Widget networkRow(String label, bool thumbnail) {
      final ping = report.value?.ping;
      final pingFailed = !thumbnail && ping != null && !ping.reachable;
      final value = check(thumbnail) ?? (pingFailed ? ping : null);
      final pending =
          !running || report.isLoading || value?.outcome == ProbeOutcome.skipped || (!report.hasError && value == null);
      final state = pending
          ? _ResultState.waiting
          : report.hasError || !value!.reachable
          ? _ResultState.failed
          : _ResultState.passed;
      final detail = !running
          ? 'в ожидании подключения'
          : report.isLoading
          ? 'проверяем…'
          : report.hasError
          ? 'не удалось завершить проверку'
          : pingFailed
          ? 'не выполнялась: пинг — ${_describe(ping)}'
          : value == null
          ? 'в ожидании предыдущей проверки'
          : _describe(value);
      return _ResultRow(
        text: '$label: $detail',
        state: state,
        rowKey: thumbnail ? 'thumbnail-result' : 'youtube-result',
      );
    }

    final playbackState = !running ? PlaybackStatus.idle : playback?.status ?? PlaybackStatus.idle;
    final playbackResult = switch (playbackState) {
      PlaybackStatus.passed => 'подтверждено: ${playback!.seconds.toStringAsFixed(1)} с, ${playback.frames} кадров',
      PlaybackStatus.checking => 'в процессе тестирования — ${playback!.percent}%',
      PlaybackStatus.failed => 'не подтверждено',
      PlaybackStatus.unsupported => 'не поддерживается',
      PlaybackStatus.cancelled => 'проверка отменена',
      PlaybackStatus.idle =>
        !running
            ? 'в ожидании подключения'
            : playbackSupported
            ? 'в ожидании'
            : 'не проверяется',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Tooltip(
                    message: 'Тестовое видео',
                    child: TextButton.icon(
                      onPressed: running && (!playbackSupported || enabled)
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
                  onPressed: running && !report.isLoading
                      ? () {
                          ref.invalidate(youtubeVerificationCacheProvider);
                          ref.invalidate(youtubeReportProvider);
                          ref.invalidate(youtubePlaybackProvider);
                        }
                      : null,
                  icon: const PlatformIcon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 8),
            networkRow('YouTube', false),
            const SizedBox(height: 8),
            networkRow('Миниатюры', true),
            const SizedBox(height: 8),
            _ResultRow(
              text: 'Воспроизведение: $playbackResult',
              state: switch (playbackState) {
                PlaybackStatus.passed => _ResultState.passed,
                PlaybackStatus.failed || PlaybackStatus.unsupported => _ResultState.failed,
                _ => _ResultState.waiting,
              },
              rowKey: 'playback-result',
            ),
          ],
        ),
      ),
    );
  }

  String _describe(ProbeResult check) => switch (check.outcome) {
    ProbeOutcome.skipped => 'в ожидании предыдущей проверки',
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

enum _ResultState { waiting, passed, failed }

class _ResultRow extends StatelessWidget {
  const _ResultRow({required this.text, required this.state, required this.rowKey});
  final String text;
  final _ResultState state;
  final String rowKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (state) {
      _ResultState.passed => Colors.green,
      _ResultState.failed => theme.colorScheme.error,
      _ResultState.waiting => theme.colorScheme.onSurfaceVariant,
    };
    final icon = switch (state) {
      _ResultState.passed => Icons.check_circle_outline,
      _ResultState.failed => Icons.error_outline_rounded,
      _ResultState.waiting => Icons.schedule_rounded,
    };
    final status = switch (state) {
      _ResultState.passed => 'Успешно',
      _ResultState.failed => 'Ошибка',
      _ResultState.waiting => 'В ожидании',
    };
    return Tooltip(
      message: text,
      child: Row(
        children: [
          PlatformIcon(icon, size: 20, color: color, semanticLabel: status),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, key: ValueKey(rowKey), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
