import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/candidate_ranker.dart';
import 'package:kazumi/services/plugin/playable_source_cache.dart';
import 'package:kazumi/services/plugin/source_probe.dart';

void main() {
  group('rankCandidates', () {
    test('the cached record\'s plugin is ordered first', () {
      final available = [
        _candidate('plugin_a'),
        _candidate('plugin_b'),
        _candidate('plugin_c'),
      ];
      final cached = _record('plugin_c');

      final result = rankCandidates(available: available, cached: cached);

      expect(_names(result), ['plugin_c', 'plugin_a', 'plugin_b']);
    });

    test('a cached plugin absent from available is ignored without error',
        () {
      final available = [
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ];
      final cached = _record('plugin_not_present');

      final result = rankCandidates(available: available, cached: cached);

      expect(_names(result), ['plugin_a', 'plugin_b']);
    });

    test('searchValidPlugins come after the cached one and before the rest',
        () {
      final available = [
        _candidate('plugin_a'),
        _candidate('plugin_b'),
        _candidate('plugin_c'),
        _candidate('plugin_d'),
        _candidate('plugin_e'),
      ];
      final cached = _record('plugin_c');

      final result = rankCandidates(
        available: available,
        cached: cached,
        searchValidPlugins: {'plugin_b', 'plugin_d'},
      );

      expect(_names(result), ['plugin_c', 'plugin_b', 'plugin_d', 'plugin_a', 'plugin_e']);
    });

    test('the cached plugin is not duplicated when it also appears in '
        'searchValidPlugins', () {
      final available = [
        _candidate('plugin_a'),
        _candidate('plugin_b'),
        _candidate('plugin_c'),
        _candidate('plugin_d'),
      ];
      final cached = _record('plugin_b');

      final result = rankCandidates(
        available: available,
        cached: cached,
        searchValidPlugins: {'plugin_b', 'plugin_d'},
      );

      expect(_names(result), ['plugin_b', 'plugin_d', 'plugin_a', 'plugin_c']);
      expect(result.where((c) => c.pluginName == 'plugin_b').length, 1);
    });

    test('ordering is stable within each tier (input order preserved)', () {
      final available = [
        _candidate('plugin_e'),
        _candidate('plugin_a'),
        _candidate('plugin_d'),
        _candidate('plugin_b'),
        _candidate('plugin_c'),
      ];

      final result = rankCandidates(
        available: available,
        searchValidPlugins: {'plugin_a', 'plugin_b'},
      );

      // valid tier keeps its relative input order (a before b, since a
      // precedes b in `available`), then the remainder keeps its relative
      // input order too.
      expect(_names(result), ['plugin_a', 'plugin_b', 'plugin_e', 'plugin_d', 'plugin_c']);
    });

    test('output length always equals input length', () {
      final available = [
        _candidate('plugin_a'),
        _candidate('plugin_b'),
        _candidate('plugin_c'),
        _candidate('plugin_d'),
        _candidate('plugin_e'),
      ];
      final cached = _record('plugin_c');

      final result = rankCandidates(
        available: available,
        cached: cached,
        searchValidPlugins: {'plugin_a', 'plugin_e'},
      );

      expect(result.length, available.length);
      expect(_names(result).toSet(), _names(available).toSet());
    });

    test('no cache and no valid set leaves input order unchanged', () {
      final available = [
        _candidate('plugin_c'),
        _candidate('plugin_a'),
        _candidate('plugin_b'),
      ];

      final result = rankCandidates(available: available);

      expect(_names(result), ['plugin_c', 'plugin_a', 'plugin_b']);
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

PlayableSourceRecord _record(String pluginName) {
  return PlayableSourceRecord(
    pluginName: pluginName,
    src: 'src://$pluginName',
    roadIndex: 0,
    lastGoodAt: DateTime.utc(2026, 1, 1),
  );
}

List<String> _names(List<ProbeCandidate> candidates) =>
    candidates.map((c) => c.pluginName).toList();
