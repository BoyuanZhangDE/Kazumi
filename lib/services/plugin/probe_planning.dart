/// Pure planning helpers for automatic playable-source selection. No I/O:
/// callers own fetching road lists, history, and cache records and pass the
/// results in as plain values.
library;

/// Which road/episode/offset to aim the probe at.
class EpisodeTarget {
  final int roadIndex;
  final int episodeIndex;
  final Duration offset;

  const EpisodeTarget({
    required this.roadIndex,
    required this.episodeIndex,
    required this.offset,
  });

  @override
  bool operator ==(Object other) {
    return other is EpisodeTarget &&
        other.roadIndex == roadIndex &&
        other.episodeIndex == episodeIndex &&
        other.offset == offset;
  }

  @override
  int get hashCode => Object.hash(roadIndex, episodeIndex, offset);

  @override
  String toString() =>
      'EpisodeTarget(roadIndex: $roadIndex, episodeIndex: $episodeIndex, offset: $offset)';
}

int _clampIndex(int value, int count) {
  if (count <= 0) return 0;
  return value.clamp(0, count - 1).toInt();
}

/// Picks the road/episode/offset to probe first when a show is opened. With
/// no remembered position this is road 0, episode 0, no offset. A remembered
/// position is clamped into range; if either index had to move to fit, the
/// offset is dropped since it was recorded for a different episode than the
/// one we ended up pointing at.
EpisodeTarget planInitialTarget({
  required int roadCount,
  required int episodeCount,
  int? rememberedRoadIndex,
  int? rememberedEpisodeIndex,
  Duration rememberedOffset = Duration.zero,
}) {
  if (rememberedRoadIndex == null && rememberedEpisodeIndex == null) {
    return const EpisodeTarget(
      roadIndex: 0,
      episodeIndex: 0,
      offset: Duration.zero,
    );
  }

  final road = _clampIndex(rememberedRoadIndex ?? 0, roadCount);
  final episode = _clampIndex(rememberedEpisodeIndex ?? 0, episodeCount);
  final wasClamped = (rememberedRoadIndex != null && road != rememberedRoadIndex) ||
      (rememberedEpisodeIndex != null && episode != rememberedEpisodeIndex);

  return EpisodeTarget(
    roadIndex: road,
    episodeIndex: episode,
    offset: wasClamped ? Duration.zero : rememberedOffset,
  );
}

/// Remaps an [EpisodeTarget] onto a different source when the probe race
/// landed on a source other than the one the target was computed for.
///
/// When the source did not change, the target carries over unmodified. When
/// it did change, both indices are clamped into the new source's range and
/// the offset is dropped to zero: episode numbering is not stable across
/// sources — specials/OVAs and split-cour renumbering mean "ep 12" on source
/// A may not be "ep 12" on source B, so seeking to a remembered position in a
/// possibly-different episode is worse than starting at 0.
EpisodeTarget remapForSourceSwap({
  required EpisodeTarget original,
  required int targetRoadCount,
  required int targetEpisodeCount,
  required bool sourceChanged,
}) {
  if (!sourceChanged) {
    return original;
  }
  return EpisodeTarget(
    roadIndex: _clampIndex(original.roadIndex, targetRoadCount),
    episodeIndex: _clampIndex(original.episodeIndex, targetEpisodeCount),
    offset: Duration.zero,
  );
}

/// Plugin names eligible for a recovery race: everything known for this show
/// except the source that just failed and any source already known to have
/// failed playback START for this episode. Without the second exclusion,
/// two bad sources ping-pong forever, each recovery swapping back to the
/// other (each cycle costing a full WebView resolve).
List<String> eligibleRecoveryPlugins({
  required Iterable<String> known,
  required String seedPluginName,
  required Set<String> playbackStartFailed,
}) {
  return known
      .where((name) =>
          name != seedPluginName && !playbackStartFailed.contains(name))
      .toList();
}
