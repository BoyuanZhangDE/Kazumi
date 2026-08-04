import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/pages/player/controller/player_playback_controller.dart';

void main() {
  group('isFatalPlaybackStartError', () {
    // REGRESSION: the auto-source race once picked a winner whose "video"
    // URL was actually a cover image. mpv errored but nothing fed that back
    // into source recovery, so the UI sat at playing=true, position 0:00
    // forever. This is the case that must trigger a swap.
    test('duration and position both zero, not yet triggered -> true', () {
      expect(
        isFatalPlaybackStartError(
          position: Duration.zero,
          duration: Duration.zero,
          alreadyTriggered: false,
        ),
        isTrue,
      );
    });

    test('already triggered -> false (latch prevents duplicate recovery)',
        () {
      expect(
        isFatalPlaybackStartError(
          position: Duration.zero,
          duration: Duration.zero,
          alreadyTriggered: true,
        ),
        isFalse,
      );
    });

    test(
        'nonzero duration, position still zero -> false (media loaded; '
        'paused at start must not swap)', () {
      expect(
        isFatalPlaybackStartError(
          position: Duration.zero,
          duration: const Duration(minutes: 20),
          alreadyTriggered: false,
        ),
        isFalse,
      );
    });

    test('nonzero position -> false (mid-play error must never swap)', () {
      expect(
        isFatalPlaybackStartError(
          position: const Duration(minutes: 5),
          duration: const Duration(minutes: 20),
          alreadyTriggered: false,
        ),
        isFalse,
      );
    });
  });
}
