import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/source_probe.dart';

void main() {
  group('SourceProbe', () {
    test('first candidate clearing both gates wins and returns its videoUrl',
        () async {
      final probe = SourceProbe(
        resolve: (candidate) async => 'video://${candidate.pluginName}',
        validate: (videoUrl, headers) async => true,
      );

      final result = await probe.findFirstPlayable([
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ]);

      expect(result, isNotNull);
      expect(result!.outcome, ProbeOutcome.playable);
      expect(result.videoUrl, 'video://plugin_a');
      expect(result.candidate.pluginName, 'plugin_a');
    });

    test(
        'a candidate passing resolve but failing validate does not win; '
        'a later fully-passing candidate does', () async {
      final probe = SourceProbe(
        resolve: (candidate) async => 'video://${candidate.pluginName}',
        validate: (videoUrl, headers) async => videoUrl == 'video://plugin_b',
        concurrency: 1, // force deterministic processing order
      );

      final result = await probe.findFirstPlayable([
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ]);

      expect(result, isNotNull);
      expect(result!.candidate.pluginName, 'plugin_b');
      expect(result.videoUrl, 'video://plugin_b');
    });

    test('all candidates failing returns null', () async {
      final probe = SourceProbe(
        resolve: (candidate) async => 'video://${candidate.pluginName}',
        validate: (videoUrl, headers) async => false,
      );

      final result = await probe.findFirstPlayable([
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ]);

      expect(result, isNull);
    });

    test('a resolve that throws is swallowed and the race continues',
        () async {
      final probe = SourceProbe(
        resolve: (candidate) async {
          if (candidate.pluginName == 'plugin_a') {
            throw Exception('boom');
          }
          return 'video://${candidate.pluginName}';
        },
        validate: (videoUrl, headers) async => true,
      );

      final result = await probe.findFirstPlayable([
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ]);

      expect(result, isNotNull);
      expect(result!.candidate.pluginName, 'plugin_b');
    });

    test('at most `concurrency` resolves are in flight simultaneously',
        () async {
      const concurrency = 2;
      var inFlight = 0;
      var maxInFlight = 0;
      final gates = List.generate(5, (_) => Completer<void>());

      final probe = SourceProbe(
        resolve: (candidate) async {
          final index = int.parse(candidate.pluginName.split('_').last);
          inFlight++;
          if (inFlight > maxInFlight) maxInFlight = inFlight;
          await gates[index].future;
          inFlight--;
          return 'video://${candidate.pluginName}';
        },
        validate: (videoUrl, headers) async => false,
        concurrency: concurrency,
      );

      final candidates = List.generate(5, (i) => _candidate('plugin_$i'));
      final future = probe.findFirstPlayable(candidates);

      // Let the event loop settle so the first wave of resolves is dispatched.
      await Future<void>.delayed(Duration.zero);
      expect(inFlight, concurrency,
          reason: 'exactly `concurrency` resolves should be in flight '
              'once the pool has started');

      for (final gate in gates) {
        gate.complete();
      }
      await future;

      expect(maxInFlight, concurrency,
          reason: 'the cap should never be exceeded across the whole race');
    });

    test('losers are abandoned once a winner is found', () async {
      final loserValidateCalled = Completer<void>();
      final loserGate = Completer<String>();

      final probe = SourceProbe(
        resolve: (candidate) async {
          if (candidate.pluginName == 'winner') {
            return 'video://winner';
          }
          return loserGate.future; // deliberately never completes
        },
        validate: (videoUrl, headers) async {
          if (videoUrl != 'video://winner') {
            loserValidateCalled.complete();
          }
          return true;
        },
        concurrency: 2,
      );

      final result = await probe.findFirstPlayable([
        _candidate('winner'),
        _candidate('loser'),
      ]).timeout(const Duration(seconds: 2));

      expect(result, isNotNull);
      expect(result!.candidate.pluginName, 'winner');
      expect(loserValidateCalled.isCompleted, isFalse,
          reason: 'the still-resolving loser should never reach validate');
    });

    test(
        'onProgress reports monotonically increasing completed and the '
        'correct total', () async {
      final progresses = <ProbeProgress>[];
      final candidates = [
        _candidate('plugin_a'),
        _candidate('plugin_b'),
        _candidate('plugin_c'),
      ];

      final probe = SourceProbe(
        resolve: (candidate) async => 'video://${candidate.pluginName}',
        validate: (videoUrl, headers) async => false,
        concurrency: 1,
      );

      await probe.findFirstPlayable(candidates, onProgress: progresses.add);

      expect(progresses, isNotEmpty);
      for (final p in progresses) {
        expect(p.total, candidates.length);
      }
      for (var i = 1; i < progresses.length; i++) {
        expect(progresses[i].completed,
            greaterThanOrEqualTo(progresses[i - 1].completed));
      }
      expect(progresses.last.completed, candidates.length);
    });

    test('cancel() mid-race completes findFirstPlayable with null promptly',
        () async {
      final gate = Completer<String>();
      final probe = SourceProbe(
        resolve: (candidate) => gate.future, // never resolves on its own
        validate: (videoUrl, headers) async => true,
      );

      final future = probe.findFirstPlayable([
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ]);

      await Future<void>.delayed(Duration.zero);
      probe.cancel();

      final result = await future.timeout(const Duration(seconds: 2));
      expect(result, isNull);
    });

    test('empty candidate list returns null and never calls resolve',
        () async {
      var resolveCalled = false;
      final probe = SourceProbe(
        resolve: (candidate) async {
          resolveCalled = true;
          return '';
        },
        validate: (videoUrl, headers) async => true,
      );

      final result = await probe.findFirstPlayable(const <ProbeCandidate>[]);

      expect(result, isNull);
      expect(resolveCalled, isFalse);
    });
  });
}

ProbeCandidate _candidate(String pluginName, {int roadIndex = 0}) {
  return ProbeCandidate(
    pluginName: pluginName,
    src: 'src://$pluginName',
    episodeUrl: 'https://example.com/$pluginName/ep1',
    roadIndex: roadIndex,
    useLegacyParser: false,
    httpHeaders: const {},
  );
}
