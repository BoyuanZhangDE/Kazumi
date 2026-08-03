import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';

/// Route arguments for '/video/'. Entry points hand playback context over
/// through the route instead of pre-filling a shared controller, which lets
/// [VideoPageController] live and die with the route.
sealed class VideoPlaybackArgs {
  const VideoPlaybackArgs({required this.bangumiItem});

  final BangumiItem bangumiItem;
}

class OnlineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OnlineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.plugin,
    required this.title,
    required this.src,
    required this.roads,
    required this.isManualPick,
  });

  final Plugin plugin;
  final String title;
  final String src;
  final List<Road> roads;

  /// True only when the user picked this source themselves in this session
  /// (the source sheet). A resumed history entry is a remembered default, not
  /// a choice, so it passes false and stays eligible for automatic recovery
  /// when the source has gone stale. Required rather than defaulted: getting
  /// it wrong silently disables recovery, so every call site must decide.
  final bool isManualPick;
}

/// Entry without a pre-picked source: the caller hands over whatever
/// plugin search results it already has (info page search, or a fallback
/// search when a remembered source stopped working) and
/// [VideoPageController] runs the automatic playable-source probe over them.
class AutoVideoPlaybackArgs extends VideoPlaybackArgs {
  const AutoVideoPlaybackArgs({
    required super.bangumiItem,
    required this.searchResults,
  });

  final List<PluginSearchResponse> searchResults;
}

class OfflineVideoPlaybackArgs extends VideoPlaybackArgs {
  const OfflineVideoPlaybackArgs({
    required super.bangumiItem,
    required this.pluginName,
    required this.episodeNumber,
    required this.road,
    required this.downloadedEpisodes,
  });

  final String pluginName;
  final int episodeNumber;
  final int road;
  final List<DownloadEpisode> downloadedEpisodes;
}
