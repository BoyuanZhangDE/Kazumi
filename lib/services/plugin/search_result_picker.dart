import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/utils/string_similarity.dart';

/// Picks the search result most likely to be the requested show.
///
/// Each item is scored as the maximum of [calculateSimilarity] against
/// [targetTitle] and against every entry in [aliases]; the highest scorer
/// wins, with ties resolved to the earliest item in [items].
///
/// There is no minimum score threshold: even when every item is a poor
/// match, the best of them is still returned. Rejecting everything would
/// leave auto-selection with no candidate at all, which is strictly worse
/// than a weak guess the user can still correct via 手动选择.
SearchItem? pickBestMatch({
  required List<SearchItem> items,
  required String targetTitle,
  List<String> aliases = const [],
}) {
  if (items.isEmpty) return null;

  SearchItem best = items.first;
  double bestScore = -1;
  for (final item in items) {
    double score = calculateSimilarity(item.name, targetTitle);
    for (final alias in aliases) {
      final aliasScore = calculateSimilarity(item.name, alias);
      if (aliasScore > score) score = aliasScore;
    }
    if (score > bestScore) {
      bestScore = score;
      best = item;
    }
  }
  return best;
}
