import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/download/download_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:kazumi/services/plugin/rule_engine_models.dart'
    show RuleCancelToken;

sealed class HistoryPlaybackResult {
  const HistoryPlaybackResult();
}

class HistoryPlaybackReady extends HistoryPlaybackResult {
  const HistoryPlaybackReady(this.args);

  final VideoPlaybackArgs args;
}

class HistoryPlaybackUnavailable extends HistoryPlaybackResult {
  const HistoryPlaybackUnavailable(this.reason);

  final String reason;
}

/// Restores a history entry into arguments the player route can take.
///
/// The history page and the my page share this one resolution path; cards
/// carry no source-lookup logic of their own.
class HistoryPlaybackService {
  HistoryPlaybackService(this._pluginsController, this._downloadController);

  final PluginsController _pluginsController;
  final DownloadController _downloadController;

  /// [cancelToken] lets the caller abort the online lookup, e.g. when the
  /// loading dialog it put up is dismissed.
  Future<HistoryPlaybackResult> open(
    History history, {
    RuleCancelToken? cancelToken,
  }) async {
    if (HistoryEntryKind.normalize(history.entryKind) ==
        HistoryEntryKind.offline) {
      final args = _offlineArgs(history);
      return args == null
          ? const HistoryPlaybackUnavailable('未找到可用缓存')
          : HistoryPlaybackReady(args);
    }

    final args = await _onlineArgs(history, cancelToken);
    return args == null
        ? const HistoryPlaybackUnavailable('在线源不可用，请重新选择播放源')
        : HistoryPlaybackReady(args);
  }

  Future<VideoPlaybackArgs?> _onlineArgs(
    History history,
    RuleCancelToken? cancelToken,
  ) async {
    if (history.lastSrc.isNotEmpty) {
      Plugin? targetPlugin;
      for (final plugin in _pluginsController.pluginList) {
        if (plugin.name == history.adapterName) {
          targetPlugin = plugin;
          break;
        }
      }
      if (targetPlugin != null) {
        try {
          final roads = await targetPlugin.queryChapterRoads(
            history.lastSrc,
            cancelToken: cancelToken,
          );
          if (roads.isNotEmpty) {
            return OnlineVideoPlaybackArgs(
              bangumiItem: history.bangumiItem,
              plugin: targetPlugin,
              title: history.bangumiItem.nameCn.isEmpty
                  ? history.bangumiItem.name
                  : history.bangumiItem.nameCn,
              src: history.lastSrc,
              roads: roads,
              // A remembered source, not a choice the user just made — leave
              // it eligible for automatic recovery if the resolve fails.
              isManualPick: false,
            );
          }
        } catch (_) {
          KazumiLogger().w("QueryManager: failed to query roads");
        }
      }
    }
    // The remembered source is gone, renamed, or stopped returning chapters.
    // Fall through to the same probe used from a cold start instead of
    // dead-ending on this one source.
    return _autoArgs(history, cancelToken);
  }

  /// Re-searches every plugin for this show so the caller can race them
  /// through the automatic playable-source probe, the same as opening the
  /// show from the info page fresh.
  Future<VideoPlaybackArgs?> _autoArgs(
    History history,
    RuleCancelToken? cancelToken,
  ) async {
    final keyword = history.bangumiItem.nameCn.isEmpty
        ? history.bangumiItem.name
        : history.bangumiItem.nameCn;
    final results = <PluginSearchResponse>[];
    await Future.wait(_pluginsController.pluginList.map((plugin) async {
      try {
        final result =
            await plugin.queryBangumi(keyword, cancelToken: cancelToken);
        if (result.data.isNotEmpty) {
          results.add(result);
        }
      } catch (_) {
        // Best-effort fallback probe; one plugin failing shouldn't block
        // the others from being tried.
      }
    }));
    if (results.isEmpty) {
      return null;
    }
    return AutoVideoPlaybackArgs(
      bangumiItem: history.bangumiItem,
      searchResults: results,
    );
  }

  VideoPlaybackArgs? _offlineArgs(History history) {
    final downloadedEpisodes = _downloadController.getCompletedEpisodes(
      history.bangumiItem.id,
      history.adapterName,
    );
    if (downloadedEpisodes.isEmpty) {
      return null;
    }

    // The page url pins the exact episode; the number is the legacy fallback.
    DownloadEpisode? targetEpisode;
    DownloadEpisode? numberMatch;
    for (final episode in downloadedEpisodes) {
      if (history.episodePageUrl.isNotEmpty &&
          episode.episodePageUrl == history.episodePageUrl) {
        targetEpisode = episode;
        break;
      }
      if (episode.episodeNumber == history.lastWatchEpisode) {
        numberMatch ??= episode;
      }
    }
    targetEpisode ??= numberMatch;
    if (targetEpisode == null) {
      return null;
    }

    final localPath = _downloadController.getLocalVideoPath(
      history.bangumiItem.id,
      history.adapterName,
      targetEpisode.episodeNumber,
    );
    if (localPath == null) {
      return null;
    }

    return OfflineVideoPlaybackArgs(
      bangumiItem: history.bangumiItem,
      pluginName: history.adapterName,
      episodeNumber: targetEpisode.episodeNumber,
      road: targetEpisode.road,
      downloadedEpisodes: downloadedEpisodes,
    );
  }
}
