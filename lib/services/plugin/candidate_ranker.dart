import 'package:kazumi/services/plugin/playable_source_cache.dart';
import 'package:kazumi/services/plugin/source_probe.dart';

/// Orders candidates for [SourceProbe]: the cached record's plugin first,
/// then plugins known to search-valid this launch, then everything else.
/// Stable within each tier; never drops or duplicates a candidate.
List<ProbeCandidate> rankCandidates({
  required List<ProbeCandidate> available,
  PlayableSourceRecord? cached,
  Set<String> searchValidPlugins = const {},
}) {
  final cachedTier = <ProbeCandidate>[];
  final validTier = <ProbeCandidate>[];
  final restTier = <ProbeCandidate>[];

  for (final candidate in available) {
    if (cached != null && candidate.pluginName == cached.pluginName) {
      cachedTier.add(candidate);
    } else if (searchValidPlugins.contains(candidate.pluginName)) {
      validTier.add(candidate);
    } else {
      restTier.add(candidate);
    }
  }

  return [...cachedTier, ...validTier, ...restTier];
}
