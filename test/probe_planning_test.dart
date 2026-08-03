import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/probe_planning.dart';

void main() {
  group('EpisodeTarget value equality', () {
    test('two identical targets compare equal', () {
      const a = EpisodeTarget(
        roadIndex: 1,
        episodeIndex: 2,
        offset: Duration(seconds: 30),
      );
      const b = EpisodeTarget(
        roadIndex: 1,
        episodeIndex: 2,
        offset: Duration(seconds: 30),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });

  group('planInitialTarget', () {
    test('no remembered values -> road 0, episode 0, offset zero', () {
      final result = planInitialTarget(roadCount: 3, episodeCount: 12);

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 0,
          episodeIndex: 0,
          offset: Duration.zero,
        ),
      );
    });

    test('valid remembered values in range are returned as-is with offset',
        () {
      final result = planInitialTarget(
        roadCount: 3,
        episodeCount: 12,
        rememberedRoadIndex: 1,
        rememberedEpisodeIndex: 5,
        rememberedOffset: const Duration(minutes: 2, seconds: 10),
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 1,
          episodeIndex: 5,
          offset: Duration(minutes: 2, seconds: 10),
        ),
      );
    });

    test(
        'out-of-range remembered episode index is clamped and offset is '
        'dropped', () {
      final result = planInitialTarget(
        roadCount: 3,
        episodeCount: 12,
        rememberedRoadIndex: 1,
        rememberedEpisodeIndex: 50,
        rememberedOffset: const Duration(minutes: 5),
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 1,
          episodeIndex: 11,
          offset: Duration.zero,
        ),
      );
    });

    test(
        'out-of-range remembered road index is clamped and offset is '
        'dropped', () {
      final result = planInitialTarget(
        roadCount: 3,
        episodeCount: 12,
        rememberedRoadIndex: 9,
        rememberedEpisodeIndex: 5,
        rememberedOffset: const Duration(minutes: 5),
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 2,
          episodeIndex: 5,
          offset: Duration.zero,
        ),
      );
    });

    test('negative remembered indices clamp up to 0 and drop the offset',
        () {
      final result = planInitialTarget(
        roadCount: 3,
        episodeCount: 12,
        rememberedRoadIndex: -1,
        rememberedEpisodeIndex: -4,
        rememberedOffset: const Duration(seconds: 15),
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 0,
          episodeIndex: 0,
          offset: Duration.zero,
        ),
      );
    });

    test('roadCount 0 forces roadIndex 0', () {
      final result = planInitialTarget(
        roadCount: 0,
        episodeCount: 12,
        rememberedRoadIndex: 3,
        rememberedEpisodeIndex: 5,
        rememberedOffset: const Duration(seconds: 15),
      );

      expect(result.roadIndex, 0);
    });

    test('episodeCount 0 forces episodeIndex 0', () {
      final result = planInitialTarget(
        roadCount: 3,
        episodeCount: 0,
        rememberedRoadIndex: 1,
        rememberedEpisodeIndex: 5,
        rememberedOffset: const Duration(seconds: 15),
      );

      expect(result.episodeIndex, 0);
    });

    test(
        'remembered index equal to count-1 is the top boundary of range: '
        'must not clamp and must not drop the offset', () {
      final result = planInitialTarget(
        roadCount: 3,
        episodeCount: 12,
        rememberedRoadIndex: 2,
        rememberedEpisodeIndex: 11,
        rememberedOffset: const Duration(seconds: 42),
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 2,
          episodeIndex: 11,
          offset: Duration(seconds: 42),
        ),
      );
    });
  });

  group('remapForSourceSwap', () {
    test('sourceChanged false returns original unchanged, offset intact',
        () {
      const original = EpisodeTarget(
        roadIndex: 1,
        episodeIndex: 5,
        offset: Duration(minutes: 3, seconds: 20),
      );

      final result = remapForSourceSwap(
        original: original,
        targetRoadCount: 1,
        targetEpisodeCount: 2,
        sourceChanged: false,
      );

      expect(result, original);
    });

    test(
        'sourceChanged true forces offset to zero even when indices stay '
        'in range', () {
      const original = EpisodeTarget(
        roadIndex: 1,
        episodeIndex: 5,
        offset: Duration(minutes: 3, seconds: 20),
      );

      final result = remapForSourceSwap(
        original: original,
        targetRoadCount: 3,
        targetEpisodeCount: 12,
        sourceChanged: true,
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 1,
          episodeIndex: 5,
          offset: Duration.zero,
        ),
      );
    });

    test(
        'sourceChanged true clamps indices down when the new source has '
        'fewer roads/episodes', () {
      const original = EpisodeTarget(
        roadIndex: 4,
        episodeIndex: 20,
        offset: Duration(minutes: 3, seconds: 20),
      );

      final result = remapForSourceSwap(
        original: original,
        targetRoadCount: 2,
        targetEpisodeCount: 10,
        sourceChanged: true,
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 1,
          episodeIndex: 9,
          offset: Duration.zero,
        ),
      );
    });

    test('sourceChanged true with zero target counts clamps both to 0', () {
      const original = EpisodeTarget(
        roadIndex: 4,
        episodeIndex: 20,
        offset: Duration(minutes: 3, seconds: 20),
      );

      final result = remapForSourceSwap(
        original: original,
        targetRoadCount: 0,
        targetEpisodeCount: 0,
        sourceChanged: true,
      );

      expect(
        result,
        const EpisodeTarget(
          roadIndex: 0,
          episodeIndex: 0,
          offset: Duration.zero,
        ),
      );
    });
  });
}
