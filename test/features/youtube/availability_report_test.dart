import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/youtube/youtube_probe.dart';
import 'package:hiddify/features/youtube/youtube_provider.dart';

void main() {
  String report({String tag = 'server-a', String thumbnail = 'reachable', int status = 200}) => jsonEncode({
    'tag': tag,
    // The client derives success from every check, never this summary alone.
    'reachable': true,
    'checks': [
      {'label': 'YouTube', 'outcome': 'reachable', 'elapsed_ms': 12, 'status_code': 204, 'is_thumbnail': false},
      {'label': 'Миниатюры', 'outcome': thumbnail, 'elapsed_ms': 35, 'status_code': status, 'is_thumbnail': true},
    ],
  });

  for (final outcome in ProbeOutcome.values.where((value) => value != ProbeOutcome.reachable)) {
    test('a positive YouTube result cannot mask thumbnail failure $outcome', () {
      final result = decodeAvailabilityReport(report(thumbnail: outcome.name, status: 404), expectedTag: 'server-a');
      expect(result.reachable, isFalse);
      expect(result.checks.first.reachable, isTrue);
      expect(result.configurationTag, 'server-a');
    });
  }

  test('full recovery retains thumbnail timing and the exact checked server', () {
    final result = decodeAvailabilityReport(report(), expectedTag: 'server-a');
    expect(result.reachable, isTrue);
    expect(result.checks.last.elapsed, const Duration(milliseconds: 35));
    expect(result.configurationTag, 'server-a');
  });

  test('a reply for another server or an incomplete report is rejected', () {
    expect(() => decodeAvailabilityReport(report(tag: 'server-b'), expectedTag: 'server-a'), throwsFormatException);
    expect(
      () => decodeAvailabilityReport(jsonEncode({'tag': 'server-a', 'checks': []}), expectedTag: 'server-a'),
      throwsFormatException,
    );
  });
  test('sequential reports accept stopped stages and reject false completion', () {
    final full = jsonDecode(report()) as Map<String, dynamic>;
    full['ping'] = {'outcome': 'reachable', 'elapsed_ms': 25};
    full['interval_ms'] = 1020000;
    expect(
      decodeAvailabilityReport(jsonEncode(full), expectedTag: 'server-a', sequential: true).interval,
      const Duration(minutes: 17),
    );
    full['checks'] = [((full['checks'] as List).first as Map<String, dynamic>)..['outcome'] = 'timeout'];
    expect(decodeAvailabilityReport(jsonEncode(full), expectedTag: 'server-a', sequential: true).reachable, isFalse);
    full['checks'] = [];
    expect(
      () => decodeAvailabilityReport(jsonEncode(full), expectedTag: 'server-a', sequential: true),
      throwsFormatException,
    );
    full['ping'] = {'outcome': 'timeout', 'elapsed_ms': 5000};
    final stopped = decodeAvailabilityReport(jsonEncode(full), expectedTag: 'server-a', sequential: true);
    expect(stopped.reachable, isFalse);
    expect(stopped.ping!.outcome, ProbeOutcome.timeout);
    expect(stopped.checks, isEmpty);
  });
}
