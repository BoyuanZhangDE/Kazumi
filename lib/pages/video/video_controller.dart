import 'dart:async';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/download/download_module.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/repositories/download_repository.dart';
import 'package:kazumi/services/download/download_manager.dart';
import 'package:kazumi/services/video_source/services.dart';
import 'package:kazumi/services/plugin/source_probe.dart';
import 'package:kazumi/services/plugin/m3u8_validator.dart';
import 'package:kazumi/services/plugin/http_probe_client.dart';
import 'package:kazumi/services/plugin/playable_source_cache.dart';
import 'package:kazumi/services/plugin/candidate_ranker.dart';
import 'package:kazumi/services/plugin/resolver_pool_probe_adapter.dart';
import 'package:kazumi/services/plugin/probe_planning.dart';
import 'package:kazumi/services/plugin/search_result_picker.dart';
import 'package:kazumi/bean/dialog/dialog_helper.dart';
import 'package:mobx/mobx.dart';
import 'package:kazumi/services/logging/logger.dart';
import 'package:window_manager/window_manager.dart';
import 'package:kazumi/modules/bangumi/episode_item.dart';
import 'package:kazumi/modules/comments/comment_item.dart';
import 'package:kazumi/modules/comments/comment_response.dart';
import 'package:kazumi/request/apis/bangumi_api.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/device.dart';
import 'package:kazumi/utils/episode_url.dart';
import 'package:kazumi/utils/http_headers.dart';
import 'package:kazumi/utils/media.dart';
import 'package:kazumi/utils/async_session.dart';
import 'package:kazumi/services/platform/display_mode_service.dart';

part 'video_controller.g.dart';

class VideoPageController = _VideoPageController with _$VideoPageController;

class VideoEpisodeSelection {
  const VideoEpisodeSelection({
    required this.episode,
    required this.road,
  });

  final int episode;
  final int road;

  @override
  bool operator ==(Object other) {
    return other is VideoEpisodeSelection &&
        other.episode == episode &&
        other.road == road;
  }

  @override
  int get hashCode => Object.hash(episode, road);

  @override
  String toString() {
    return 'VideoEpisodeSelection(episode: $episode, road: $road)';
  }
}

abstract class _VideoPageController with Store implements Disposable {
  _VideoPageController(
    this.historyController,
    this.downloadRepository,
    this.downloadManager,
    this.pluginsController,
  );

  late BangumiItem bangumiItem;
  EpisodeInfo episodeInfo = EpisodeInfo.fromTemplate();

  @observable
  var episodeCommentsList = ObservableList<EpisodeCommentItem>();

  // Resolution state machine: [_beginEpisodeSwitch] enters the loading state;
  // [_finishLoading] and [_failLoading] are the only terminal transitions.
  // [_errorMessage] is non-null only in the failed state.
  @readonly
  bool _loading = true;

  @readonly
  String? _errorMessage;

  @observable
  VideoEpisodeSelection selectedEpisode =
      const VideoEpisodeSelection(episode: 1, road: 0);

  @observable
  VideoEpisodeSelection? playingEpisode;

  @observable
  int commentsEpisode = 1;

  @action
  void resetEpisodeState({int episode = 1, int road = 0}) {
    final selection = VideoEpisodeSelection(episode: episode, road: road);
    selectedEpisode = selection;
    playingEpisode = null;
    commentsEpisode = commentEpisodeForSelection(selection);
  }

  VideoEpisodeSelection get playbackEpisode =>
      playingEpisode ?? selectedEpisode;

  @observable
  bool isFullscreen = false;

  @observable
  bool isCommentsAscending = false;

  // Playback, automatic danmaku loading, and comment loading have separate
  // owners. Manual danmaku selection can cancel auto danmaku without touching
  // playback; comment refreshes never cancel playback.
  final AsyncSessionOwner _playbackSessions = AsyncSessionOwner();
  final AsyncSessionOwner _danmakuSessions = AsyncSessionOwner();
  final AsyncSessionOwner _commentSessions = AsyncSessionOwner();

  @observable
  bool isPip = false;

  @observable
  bool showTabBody = true;

  @observable
  int historyOffset = 0;

  @observable
  bool isOfflineMode = false;

  PlaybackHistoryIdentity? _playbackHistoryIdentity;
  final Map<int, DownloadEpisode> _offlineEpisodesByNumber = {};
  final Map<int, int> _offlineDisplayRoadToOriginalRoad = {};
  final Map<int, int> _offlineOriginalRoadToDisplayRoad = {};

  /// Title reported by the video source; may differ from [bangumiItem]'s.
  String title = '';

  String src = '';

  @observable
  var roadList = ObservableList<Road>();

  late Plugin currentPlugin;

  /// True when [currentPlugin] reflects an explicit user pick — the initial
  /// manual source-sheet selection ([OnlineVideoPlaybackArgs]) or a later
  /// 片源 dropdown switch ([switchToSource]) — rather than a source the
  /// automatic probe race chose on the user's behalf. A failed resolve on a
  /// manual pick must not silently auto-swap it away; see
  /// [_recoverFromResolveFailure].
  bool _currentSourceIsManual = false;

  String _offlinePluginName = '';

  final HistoryController historyController;
  final IDownloadRepository downloadRepository;
  final IDownloadManager downloadManager;
  final PluginsController pluginsController;

  WebViewVideoSourceService? _videoSourceService;

  // Automatic playable-source selection (see docs/ideas/source-auto-selection.md).
  final VideoSourceResolverPool _resolverPool = VideoSourceResolverPool();
  late final ResolverPoolProbeAdapter _probeAdapter =
      ResolverPoolProbeAdapter(_resolverPool);
  late final SourceProbe _sourceProbe = SourceProbe(
    resolve: _probeAdapter.resolve,
    validate: M3u8Validator(get: httpProbeGet).validate,
    concurrency: 3,
  );
  late final PlayableSourceCache _playableSourceCache = PlayableSourceCache(
    read: _readPlayableSourceCacheJson,
    write: _writePlayableSourceCacheJson,
  );

  /// Chapter roads fetched per plugin while probing, keyed by plugin name.
  /// Kept around so the 片源 dropdown and mid-race road-list swap don't need
  /// to re-query.
  final Map<String, _SourceCandidate> _sourceCandidatesByPlugin = {};
  Timer? _probePanelTimer;

  @observable
  var availableSourceNames = ObservableList<String>();

  /// Plugin names in the order this race is probing them, for the progress
  /// panel's status chips.
  @observable
  var probeCandidateOrder = ObservableList<String>();

  /// Plugin names that have cleared both gates or failed one, in completion
  /// order. Live-accurate: [SourceProbe] only reports a candidate through
  /// [onProgress] once it has actually settled, and the winner is always the
  /// last entry once the race resolves with a win.
  @observable
  var probeCompletedOrder = ObservableList<String>();

  @readonly
  ProbeProgress? _probeProgress;

  @readonly
  bool _showSourceSelectionPanel = false;

  @readonly
  bool _probeExhausted = false;

  final StreamController<String> _logStreamController =
      StreamController<String>.broadcast();

  Stream<String> get logStream => _logStreamController.stream;

  StreamSubscription<String>? _logSubscription;

  /// Applies the route arguments exactly once, from [VideoPage.initState].
  @action
  void applyPlaybackArgs(VideoPlaybackArgs args) {
    switch (args) {
      case OnlineVideoPlaybackArgs():
        bangumiItem = args.bangumiItem;
        currentPlugin = args.plugin;
        title = args.title;
        src = args.src;
        roadList.clear();
        roadList.addAll(args.roads);
        availableSourceNames = ObservableList.of([currentPlugin.name]);
        // Reached both by the source sheet's explicit tap-to-pick flow and by
        // resuming a history entry; only the former counts as a deliberate
        // choice that recovery must not override.
        _currentSourceIsManual = args.isManualPick;
      case OfflineVideoPlaybackArgs():
        _initForOfflinePlayback(
          bangumiItem: args.bangumiItem,
          pluginName: args.pluginName,
          episodeNumber: args.episodeNumber,
          road: args.road,
          downloadedEpisodes: args.downloadedEpisodes,
        );
      case AutoVideoPlaybackArgs():
        bangumiItem = args.bangumiItem;
        currentPlugin = Plugin.fromTemplate();
        title = bangumiItem.nameCn.isNotEmpty ? bangumiItem.nameCn : bangumiItem.name;
        src = '';
        roadList.clear();
        _autoSearchResults = args.searchResults;
        _currentSourceIsManual = false;
    }
  }

  /// Stashed by [applyPlaybackArgs] for [AutoVideoPlaybackArgs]; consumed by
  /// [beginAutoSourceSelection], which [VideoPage] calls once it has a
  /// [PlayerController] ready.
  List<PluginSearchResponse> _autoSearchResults = const [];

  @action
  void _initForOfflinePlayback({
    required BangumiItem bangumiItem,
    required String pluginName,
    required int episodeNumber,
    required int road,
    required List<DownloadEpisode> downloadedEpisodes,
  }) {
    this.bangumiItem = bangumiItem;
    _offlinePluginName = pluginName;
    title =
        bangumiItem.nameCn.isNotEmpty ? bangumiItem.nameCn : bangumiItem.name;
    isOfflineMode = true;
    _loading = false;

    _buildOfflineRoadList(downloadedEpisodes);

    final target = _findOfflineEpisodeByNumber(
      episodeNumber,
      preferredOriginalRoad: road,
    );
    final selected = VideoEpisodeSelection(
      episode: target?.listIndex ?? 1,
      road: target?.roadIndex ?? 0,
    );
    selectedEpisode = selected;
    playingEpisode = null;
    commentsEpisode = commentEpisodeForSelection(selected);
    final resolvedEpisode = _resolveOfflineEpisode(
      selected.episode,
      road: selected.road,
    );
    if (resolvedEpisode != null) {
      _setOfflineHistoryIdentity(resolvedEpisode);
    } else {
      _playbackHistoryIdentity = null;
    }
    KazumiLogger().i(
        'VideoPageController: initialized for offline playback, episode $episodeNumber (position: ${selected.episode})');
  }

  void _buildOfflineRoadList(List<DownloadEpisode> episodes) {
    final snapshot = buildOfflineRoadListSnapshot(episodes);
    roadList.clear();
    roadList.addAll(snapshot.roads);
    _offlineEpisodesByNumber.clear();
    _offlineEpisodesByNumber.addAll(snapshot.episodesByNumber);
    _offlineDisplayRoadToOriginalRoad.clear();
    _offlineDisplayRoadToOriginalRoad
        .addAll(snapshot.displayRoadToOriginalRoad);
    _offlineOriginalRoadToDisplayRoad.clear();
    _offlineOriginalRoadToDisplayRoad
        .addAll(snapshot.originalRoadToDisplayRoad);
  }

  String get offlinePluginName => _offlinePluginName;

  PlaybackHistoryIdentity? get currentHistoryIdentity =>
      _playbackHistoryIdentity;

  ({int listIndex, int roadIndex})? _findOfflineEpisodeByNumber(
    int episodeNumber, {
    required int preferredOriginalRoad,
  }) {
    if (episodeNumber <= 0 || roadList.isEmpty) {
      return null;
    }
    final preferredDisplayRoad =
        _offlineOriginalRoadToDisplayRoad[preferredOriginalRoad];
    final roadIndices = <int>[
      if (preferredDisplayRoad != null) preferredDisplayRoad,
      for (var i = 0; i < roadList.length; i++)
        if (i != preferredDisplayRoad) i,
    ];
    for (final roadIndex in roadIndices) {
      final match = _findOfflineEpisodeInDisplayRoad(episodeNumber, roadIndex);
      if (match != null) {
        return match;
      }
    }
    return null;
  }

  ({int listIndex, int roadIndex})? _findOfflineEpisodeInDisplayRoad(
    int episodeNumber,
    int roadIndex,
  ) {
    if (roadIndex < 0 || roadIndex >= roadList.length) {
      return null;
    }
    final index = roadList[roadIndex].data.indexOf(episodeNumber.toString());
    if (index < 0) {
      return null;
    }
    return (listIndex: index + 1, roadIndex: roadIndex);
  }

  int getHistoryOffsetFor(PlaybackHistoryIdentity identity) {
    final playResume = GStorage.getSetting(SettingsKeys.playResume);
    if (playResume != true) {
      return 0;
    }
    return historyController
            .findProgress(
              identity.bangumiItem,
              identity.pluginName,
              identity.episodeNumber,
              entryKind: identity.entryKind,
            )
            ?.progress
            .inSeconds ??
        0;
  }

  void _setOnlineHistoryIdentity(EpisodeRef episode) {
    _playbackHistoryIdentity = PlaybackHistoryIdentity.online(
      bangumiItem: bangumiItem,
      pluginName: currentPlugin.name,
      episodeNumber: episode.historyEpisodeNumber,
      episodeTitle: episode.displayTitle,
      road: episode.originalRoadIndex,
      onlineBangumiSrc: src,
      episodePageUrl: episode.pageUrl,
    );
  }

  void _setOfflineHistoryIdentity(EpisodeRef episode) {
    _playbackHistoryIdentity = PlaybackHistoryIdentity.offline(
      bangumiItem: bangumiItem,
      pluginName: _offlinePluginName,
      episodeNumber: episode.historyEpisodeNumber,
      episodeTitle: episode.displayTitle,
      road: episode.originalRoadIndex,
      episodePageUrl: episode.pageUrl,
    );
  }

  EpisodeRef? _resolveOnlineEpisode(int episode, {int? road}) {
    final targetRoad = road ?? selectedEpisode.road;
    if (roadList.isEmpty || targetRoad < 0 || targetRoad >= roadList.length) {
      return null;
    }
    final roadData = roadList[targetRoad];
    final index = episode - 1;
    if (index < 0 ||
        index >= roadData.data.length ||
        index >= roadData.identifier.length) {
      return null;
    }
    final displayTitle = roadData.identifier[index];
    return EpisodeRef.online(
      listIndex: episode,
      roadIndex: targetRoad,
      displayTitle: displayTitle,
      pageUrl: roadData.data[index],
    );
  }

  EpisodeRef? _resolveOfflineEpisode(int episode, {int? road}) {
    final targetRoad = road ?? selectedEpisode.road;
    if (roadList.isEmpty || targetRoad < 0 || targetRoad >= roadList.length) {
      return null;
    }
    final roadData = roadList[targetRoad];
    final index = episode - 1;
    if (index < 0 ||
        index >= roadData.data.length ||
        index >= roadData.identifier.length) {
      return null;
    }
    final episodeNumber = int.tryParse(roadData.data[index]);
    if (episodeNumber == null) {
      return null;
    }
    final downloadEpisode = _offlineEpisodesByNumber[episodeNumber];
    final titleFromRoad = roadData.identifier[index];
    final episodeTitle = downloadEpisode?.episodeName.isNotEmpty == true
        ? downloadEpisode!.episodeName
        : (titleFromRoad.isNotEmpty ? titleFromRoad : '第$episodeNumber集');
    return EpisodeRef.offline(
      listIndex: episode,
      roadIndex: targetRoad,
      displayTitle: episodeTitle,
      pageUrl: downloadEpisode?.episodePageUrl ?? '',
      episodeNumber: episodeNumber,
      originalRoadIndex: downloadEpisode?.road ??
          _offlineDisplayRoadToOriginalRoad[targetRoad] ??
          targetRoad,
    );
  }

  EpisodeRef? resolveEpisode(VideoEpisodeSelection selection) {
    return isOfflineMode
        ? _resolveOfflineEpisode(selection.episode, road: selection.road)
        : _resolveOnlineEpisode(selection.episode, road: selection.road);
  }

  int commentEpisodeForSelection(VideoEpisodeSelection selection) {
    final resolvedEpisode = resolveEpisode(selection);
    return resolvedEpisode?.danmakuEpisodeNumber ?? selection.episode;
  }

  /// Resets pre-switch state as a single transaction so observers see one
  /// notification instead of one per field.
  @action
  void _beginEpisodeSwitch(VideoEpisodeSelection selection) {
    final targetCommentsEpisode = commentEpisodeForSelection(selection);
    selectedEpisode = selection;
    playingEpisode = null;
    // The comments sheet only re-queries when [commentsEpisode] changes, so
    // resetting comment state here without changing it would blank the sheet
    // permanently.
    if (targetCommentsEpisode != commentsEpisode) {
      commentsEpisode = targetCommentsEpisode;
      _resetEpisodeComments();
    }
    _loading = true;
    _errorMessage = null;
    // Each switch attempt starts on a clean slate; otherwise a stale `true`
    // left over from an earlier failed recovery would mislabel an unrelated
    // failure (e.g. '集数解析失败') as the friendly source-exhausted widget.
    _probeExhausted = false;
  }

  @action
  void _applyResolvedSelection(EpisodeRef resolvedEpisode) {
    selectedEpisode = VideoEpisodeSelection(
      episode: resolvedEpisode.listIndex,
      road: resolvedEpisode.roadIndex,
    );
    commentsEpisode = commentEpisodeForSelection(selectedEpisode);
  }

  @action
  void _finishLoading() {
    _loading = false;
  }

  @action
  void _failLoading(String message) {
    _loading = false;
    _errorMessage = message;
  }

  Future<void> changeEpisode(
    int episode, {
    int currentRoad = 0,
    int offset = 0,
    required PlayerController playerController,
  }) async {
    final session = _playbackSessions.begin();
    final selection = VideoEpisodeSelection(
      episode: episode,
      road: currentRoad,
    );
    _beginEpisodeSwitch(selection);
    _danmakuSessions.cancel();
    playerController.danmaku.finishDanmakuLoad();
    _videoSourceService?.cancel();
    // A manual episode/road/source switch while the automatic probe from
    // page entry is still racing supersedes it; stop holding its WebView
    // workers instead of letting it run to completion in the background.
    _sourceProbe.cancel();

    await playerController.stop();
    if (session.isStale) {
      return;
    }

    if (isOfflineMode) {
      await _changeOfflineEpisode(
        selection,
        offset,
        session: session,
        playerController: playerController,
      );
      return;
    }

    final resolvedEpisode = _resolveOnlineEpisode(episode, road: currentRoad);
    if (resolvedEpisode == null) {
      KazumiLogger().e(
          'VideoPageController: failed to resolve online episode. road=$currentRoad, episode=$episode');
      _failLoading('集数解析失败');
      return;
    }

    _applyResolvedSelection(resolvedEpisode);
    _setOnlineHistoryIdentity(resolvedEpisode);

    KazumiLogger()
        .i('VideoPageController: changed to ${resolvedEpisode.displayTitle}');
    final urlItem = normalizeEpisodeUrl(
      currentPlugin.baseUrl,
      resolvedEpisode.pageUrl,
    );

    await _resolveWithVideoSourceService(
      urlItem,
      offset,
      resolvedEpisode: resolvedEpisode,
      session: session,
      playerController: playerController,
    );
  }

  Future<void> _changeOfflineEpisode(
    VideoEpisodeSelection selection,
    int offset, {
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    final resolvedEpisode =
        _resolveOfflineEpisode(selection.episode, road: selection.road);
    if (resolvedEpisode == null) {
      KazumiLogger().e(
          'VideoPageController: failed to resolve offline episode. road=${selection.road}, episode=${selection.episode}');
      _failLoading('集数解析失败');
      return;
    }

    final localPath = _getLocalVideoPath(
      bangumiItem.id,
      _offlinePluginName,
      resolvedEpisode.historyEpisodeNumber,
    );
    if (localPath == null) {
      _failLoading('该集数未下载');
      return;
    }
    _applyResolvedSelection(resolvedEpisode);
    _setOfflineHistoryIdentity(resolvedEpisode);
    if (session.isStale) {
      return;
    }
    _finishLoading();
    final resolvedOffset =
        offset > 0 ? offset : getHistoryOffsetFor(_playbackHistoryIdentity!);

    KazumiLogger().i(
        'VideoPageController: offline episode changed to ${resolvedEpisode.historyEpisodeNumber} (index: ${selection.episode}), path: $localPath');

    final params = PlaybackInitParams(
      videoUrl: localPath,
      offset: resolvedOffset,
      isLocalPlayback: true,
      bangumiId: bangumiItem.id,
      pluginName: _offlinePluginName,
      episode: resolvedEpisode.listIndex,
      danmakuEpisodeNumber: resolvedEpisode.danmakuEpisodeNumber,
      pageUrl: resolvedEpisode.pageUrl,
      sortNumber: resolvedEpisode.sortNumber,
      httpHeaders: {},
      adBlockerEnabled: false,
      episodeTitle: resolvedEpisode.displayTitle,
      referer: '',
      currentRoad: resolvedEpisode.roadIndex,
      coverUrl: bangumiItem.images['large'],
      bangumiName:
          bangumiItem.nameCn.isNotEmpty ? bangumiItem.nameCn : bangumiItem.name,
    );

    final initialized = await playerController.init(params);
    if (session.isActive && initialized) {
      playingEpisode = selection;
      unawaited(_loadPlaybackDanmaku(playerController, params, session));
    } else if (session.isActive) {
      _playbackSessions.cancel();
    }
  }

  Future<void> _loadPlaybackDanmaku(
    PlayerController playerController,
    PlaybackInitParams params,
    AsyncSession session,
  ) async {
    final danmakuSession = _danmakuSessions.begin();
    playerController.danmaku.beginDanmakuLoad();
    try {
      final result = await playerController.danmaku.fetchDanmaku(
        params.bangumiId,
        params.pluginName,
        params.danmakuEpisodeNumber,
      );
      if (session.isActive && danmakuSession.isActive) {
        if (result.hasDanmakus) {
          final bool enableDanmaku =
              GStorage.getSetting(SettingsKeys.danmakuEnabledByDefault);
          playerController.danmaku.applyDanmakuLoad(
            result,
            enableDanmaku: enableDanmaku,
          );
        } else {
          playerController.danmaku.applyUnavailableDanmakuLoad(result);
          if (result.isFailed) {
            KazumiDialog.showToast(message: '弹幕加载失败，可手动检索');
          }
        }
      }
    } catch (e) {
      if (session.isActive && danmakuSession.isActive) {
        playerController.danmaku.finishDanmakuLoad(disableDanmaku: true);
        KazumiDialog.showToast(message: '弹幕加载失败，可手动检索');
      }
      KazumiLogger().w('VideoPageController: failed to load danmaku', error: e);
    }
  }

  void cancelAutomaticDanmakuLoad() {
    _danmakuSessions.cancel();
  }

  String? _getLocalVideoPath(
      int bangumiId, String pluginName, int episodeNumber) {
    final episode =
        downloadRepository.getEpisode(bangumiId, pluginName, episodeNumber);
    return downloadManager.getLocalVideoPath(episode);
  }

  Future<void> _resolveWithVideoSourceService(
    String url,
    int offset, {
    required EpisodeRef resolvedEpisode,
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    _videoSourceService ??= WebViewVideoSourceService();

    await _logSubscription?.cancel();
    _logSubscription = _videoSourceService!.onLog.listen((log) {
      if (!_logStreamController.isClosed) {
        _logStreamController.add(log);
      }
    });

    try {
      final source = await _videoSourceService!.resolve(
        url,
        useLegacyParser: currentPlugin.useLegacyParser,
        offset: offset,
      );

      if (session.isStale) {
        return;
      }
      _finishLoading();
      KazumiLogger()
          .i('VideoPageController: resolved video URL: ${source.url}');

      final bool forceAdBlocker =
          GStorage.getSetting(SettingsKeys.forceAdBlocker);

      final params = PlaybackInitParams(
        videoUrl: source.url,
        offset: source.offset,
        isLocalPlayback: false,
        bangumiId: bangumiItem.id,
        pluginName: currentPlugin.name,
        episode: resolvedEpisode.listIndex,
        danmakuEpisodeNumber: resolvedEpisode.danmakuEpisodeNumber,
        pageUrl: resolvedEpisode.pageUrl,
        sortNumber: resolvedEpisode.sortNumber,
        httpHeaders: {
          'user-agent': currentPlugin.userAgent.isEmpty
              ? getRandomUA()
              : currentPlugin.userAgent,
          if (currentPlugin.referer.isNotEmpty)
            'referer': currentPlugin.referer,
        },
        adBlockerEnabled: forceAdBlocker || currentPlugin.adBlocker,
        episodeTitle: resolvedEpisode.displayTitle,
        referer: currentPlugin.referer,
        currentRoad: resolvedEpisode.roadIndex,
        coverUrl: bangumiItem.images['large'],
        bangumiName: bangumiItem.nameCn.isNotEmpty
            ? bangumiItem.nameCn
            : bangumiItem.name,
      );

      final initialized = await playerController.init(params);
      if (session.isActive && initialized) {
        playingEpisode = VideoEpisodeSelection(
          episode: resolvedEpisode.listIndex,
          road: resolvedEpisode.roadIndex,
        );
        unawaited(_loadPlaybackDanmaku(playerController, params, session));
      } else if (session.isActive) {
        _playbackSessions.cancel();
      }
    } on VideoSourceTimeoutException {
      if (session.isStale) {
        return;
      }
      await _recoverFromResolveFailure(
        session: session,
        playerController: playerController,
      );
    } on VideoSourceCancelledException {
      KazumiLogger().i('VideoPageController: video URL resolution cancelled');
    } catch (e) {
      if (session.isStale) {
        return;
      }
      KazumiLogger().w('VideoPageController: resolve failed, attempting recovery',
          error: e);
      await _recoverFromResolveFailure(
        session: session,
        playerController: playerController,
      );
    }
  }

  int _episodeCountFor(List<Road> roads) =>
      roads.isNotEmpty ? roads.first.data.length : 0;

  String? _readPlayableSourceCacheJson() {
    final raw = GStorage.getSetting(SettingsKeys.playableSourceCache);
    return raw.isEmpty ? null : raw;
  }

  Future<void> _writePlayableSourceCacheJson(String json) {
    return GStorage.putSetting(SettingsKeys.playableSourceCache, json);
  }

  /// Most recently watched online history entry for this show, regardless of
  /// which plugin it was watched on — the seed for "the episode the user is
  /// actually about to watch".
  History? _mostRecentOnlineHistory(int bangumiId) {
    History? best;
    for (final history in historyController.histories) {
      if (history.bangumiItem.id != bangumiId) continue;
      if (HistoryEntryKind.normalize(history.entryKind) !=
          HistoryEntryKind.online) {
        continue;
      }
      if (best == null || history.lastWatchTime.isAfter(best.lastWatchTime)) {
        best = history;
      }
    }
    return best;
  }

  @action
  void _setProbeProgress(ProbeProgress? progress) {
    _probeProgress = progress;
    final name = progress?.currentPluginName;
    if (name != null) {
      probeCompletedOrder.add(name);
    }
  }

  @action
  void _setShowSourceSelectionPanel(bool value) {
    _showSourceSelectionPanel = value;
  }

  void _startProbePanelTimer(AsyncSession session) {
    // Already visible (carried over from an earlier phase of the same
    // auto-selection run) — don't restart the countdown, it would just be a
    // redundant Timer with no visible effect.
    if (_showSourceSelectionPanel) return;
    _probePanelTimer?.cancel();
    _probePanelTimer = Timer(const Duration(seconds: 3), () {
      if (session.isActive) {
        _setShowSourceSelectionPanel(true);
      }
    });
  }

  /// Stops the countdown without hiding an already-visible panel. Use this
  /// at phase boundaries that continue on to more waiting; use
  /// [_cancelProbePanelTimer] at genuine end states.
  void _stopProbePanelTimer() {
    _probePanelTimer?.cancel();
    _probePanelTimer = null;
  }

  void _cancelProbePanelTimer() {
    _stopProbePanelTimer();
    _setShowSourceSelectionPanel(false);
  }

  @action
  void _beginAutoSelection() {
    _loading = true;
    _errorMessage = null;
    _probeExhausted = false;
    probeCandidateOrder.clear();
    probeCompletedOrder.clear();
  }

  /// Also clears [probeCompletedOrder]: called once per race (entry or
  /// recovery), so any dots left over from a previous race must not carry
  /// over into this one.
  @action
  void _setProbeCandidateOrder(List<String> names) {
    probeCandidateOrder
      ..clear()
      ..addAll(names);
    probeCompletedOrder.clear();
  }

  @action
  void _failAutoSelection(String message) {
    _probeExhausted = true;
    _loading = false;
    _errorMessage = message;
  }

  /// Points the episode grid, 片源 dropdown and history identity at
  /// [pluginName], without touching playback. Used both to show the grid the
  /// instant stage 2 (chapter roads) resolves, and to swap the display when
  /// the probe race lands on a different source than expected.
  @action
  void _applyDisplaySource(String pluginName, EpisodeTarget target) {
    final source = _sourceCandidatesByPlugin[pluginName]!;
    currentPlugin = source.plugin;
    src = source.src;
    title = source.title;
    roadList
      ..clear()
      ..addAll(source.roads);
    availableSourceNames = ObservableList.of(_sourceCandidatesByPlugin.keys);
    selectedEpisode = VideoEpisodeSelection(
      episode: target.episodeIndex + 1,
      road: target.roadIndex,
    );
    playingEpisode = null;
    commentsEpisode = commentEpisodeForSelection(selectedEpisode);
  }

  /// Resolves each plugin's search hit into a probeable candidate: picks the
  /// most likely match per plugin (see [pickBestMatch], since scrapers
  /// routinely return fuzzy matches) and fetches its chapter roads. Shared
  /// by the info-page snapshot and the in-player fallback search.
  Future<void> _collectSourceCandidates(
    List<PluginSearchResponse> searchResults,
  ) async {
    final targetTitle =
        bangumiItem.nameCn.isNotEmpty ? bangumiItem.nameCn : bangumiItem.name;
    await Future.wait(searchResults.map((response) async {
      if (response.data.isEmpty) return;
      Plugin? plugin;
      for (final candidate in pluginsController.pluginList) {
        if (candidate.name == response.pluginName) {
          plugin = candidate;
          break;
        }
      }
      if (plugin == null) return;
      final item = pickBestMatch(
        items: response.data,
        targetTitle: targetTitle,
        aliases: bangumiItem.alias,
      );
      if (item == null) return;
      try {
        final roads = await plugin.queryChapterRoads(item.src);
        if (roads.isNotEmpty) {
          _sourceCandidatesByPlugin[plugin.name] = _SourceCandidate(
            plugin: plugin,
            src: item.src,
            title: item.name,
            roads: roads,
          );
        }
      } catch (_) {
        // A single source failing stage 2 (chapter roads) shouldn't block
        // the others from being probed.
      }
    }));
  }

  /// Re-searches every plugin for this show, for when the info-page snapshot
  /// yields nothing usable. Mirrors HistoryPlaybackService._autoArgs, which
  /// does the same re-search when a remembered source is gone.
  Future<List<PluginSearchResponse>> _searchAllPluginsForAutoSelection() async {
    final keyword =
        bangumiItem.nameCn.isNotEmpty ? bangumiItem.nameCn : bangumiItem.name;
    final results = <PluginSearchResponse>[];
    await Future.wait(pluginsController.pluginList.map((plugin) async {
      try {
        final result = await plugin.queryBangumi(keyword);
        if (result.data.isNotEmpty) {
          results.add(result);
        }
      } catch (_) {
        // Best-effort fallback search; one plugin failing shouldn't block
        // the others from being tried.
      }
    }));
    return results;
  }

  /// Entry point for [AutoVideoPlaybackArgs]: races the search results
  /// gathered by the caller through the two-gate playable-source probe and
  /// plays the winner. See docs/ideas/source-auto-selection.md.
  Future<void> beginAutoSourceSelection({
    required PlayerController playerController,
  }) async {
    final session = _playbackSessions.begin();
    _beginAutoSelection();
    _sourceCandidatesByPlugin.clear();

    await _collectSourceCandidates(_autoSearchResults);

    if (session.isStale) return;

    if (_sourceCandidatesByPlugin.isEmpty) {
      // The info-page snapshot is an optimisation, not a promise: its search
      // fans out across every plugin from initState and can still be
      // running when 开始观看 is tapped, so zero candidates here doesn't mean
      // the show has no sources. Search ourselves before giving up — the
      // same primitive HistoryPlaybackService._autoArgs uses to recover a
      // stale source.
      _startProbePanelTimer(session);
      final freshResults = await _searchAllPluginsForAutoSelection();
      // Stop the countdown but don't hide the panel here: this is a phase
      // boundary, not an end state — the probe race (phase 2) starts right
      // after, and if phase 1 ran long enough to show the panel, hiding it
      // now would just flash it off and back on. Genuine exits below hide
      // it explicitly.
      _stopProbePanelTimer();
      if (session.isStale) {
        _cancelProbePanelTimer();
        return;
      }
      await _collectSourceCandidates(freshResults);
      if (session.isStale) {
        _cancelProbePanelTimer();
        return;
      }
      if (_sourceCandidatesByPlugin.isEmpty) {
        _cancelProbePanelTimer();
        _failAutoSelection('未找到可播放的片源');
        return;
      }
    }

    // Rank first (only needs plugin names), then seed the target episode
    // from whichever source ranked first.
    final rankingStubs = _sourceCandidatesByPlugin.keys
        .map((name) => ProbeCandidate(
              pluginName: name,
              src: '',
              episodeUrl: '',
              roadIndex: 0,
              useLegacyParser: false,
              httpHeaders: const {},
            ))
        .toList();
    final searchValidPlugins = pluginsController.pluginList
        .where((p) => pluginsController.validityTracker.isSearchValid(p.name))
        .map((p) => p.name)
        .toSet();
    final cachedRecord = _playableSourceCache.get(bangumiItem.id);
    final rankedNames = rankCandidates(
      available: rankingStubs,
      cached: cachedRecord,
      searchValidPlugins: searchValidPlugins,
    ).map((c) => c.pluginName).toList();

    final seedPluginName = rankedNames.first;
    final seed = _sourceCandidatesByPlugin[seedPluginName]!;
    final rememberedHistory = _mostRecentOnlineHistory(bangumiItem.id);
    final rememberedMatchesSeed = rememberedHistory != null &&
        rememberedHistory.adapterName == seedPluginName;
    final playResumeEnabled = GStorage.getSetting(SettingsKeys.playResume);
    final seedProgress = rememberedMatchesSeed
        ? rememberedHistory.progresses[rememberedHistory.lastWatchEpisode]
        : null;
    final seedTarget = planInitialTarget(
      roadCount: seed.roads.length,
      episodeCount: _episodeCountFor(seed.roads),
      rememberedRoadIndex: rememberedMatchesSeed ? (seedProgress?.road ?? 0) : null,
      rememberedEpisodeIndex:
          rememberedMatchesSeed ? rememberedHistory.lastWatchEpisode - 1 : null,
      rememberedOffset: rememberedMatchesSeed && playResumeEnabled
          ? (seedProgress?.progress ?? Duration.zero)
          : Duration.zero,
    );

    // Episode grid live before the WebView race even starts.
    _applyDisplaySource(seedPluginName, seedTarget);

    final targetByPlugin = <String, EpisodeTarget>{seedPluginName: seedTarget};
    final candidates = <ProbeCandidate>[];
    for (final name in rankedNames) {
      final source = _sourceCandidatesByPlugin[name]!;
      final target = name == seedPluginName
          ? seedTarget
          : remapForSourceSwap(
              original: seedTarget,
              targetRoadCount: source.roads.length,
              targetEpisodeCount: _episodeCountFor(source.roads),
              sourceChanged: true,
            );
      if (target.roadIndex >= source.roads.length) continue;
      final roadData = source.roads[target.roadIndex];
      if (target.episodeIndex >= roadData.data.length) continue;
      targetByPlugin[name] = target;
      candidates.add(ProbeCandidate(
        pluginName: name,
        src: source.src,
        episodeUrl: source.plugin.buildFullUrl(roadData.data[target.episodeIndex]),
        roadIndex: target.roadIndex,
        useLegacyParser: source.plugin.useLegacyParser,
        httpHeaders: source.plugin.buildHttpHeaders(),
      ));
    }

    if (candidates.isEmpty) {
      _cancelProbePanelTimer();
      _failAutoSelection('未找到可播放的片源');
      return;
    }

    final result = await _raceCandidates(
      candidates,
      targetByPlugin,
      seedPluginName: seedPluginName,
      session: session,
      playerController: playerController,
    );

    if (session.isStale) return;

    if (result == null) {
      _failAutoSelection('该集数暂时没有可用片源，可能还未收录');
    }
  }

  /// Races [candidates] (already ranked, one [EpisodeTarget] per plugin name
  /// in [targetByPlugin]) through the two-gate probe. On a win: persists the
  /// cache record, switches the display source when the winner isn't
  /// [seedPluginName] (with the '已切换到' toast), and plays it. Shared by
  /// [beginAutoSourceSelection] (entry) and [_recoverFromResolveFailure]
  /// (post-entry recovery) so there is exactly one race implementation.
  ///
  /// Returns the winning [ProbeResult], or null when every candidate failed
  /// or [session] went stale mid-race — callers distinguish the two by
  /// re-checking `session.isStale` themselves, same as before this was
  /// factored out.
  Future<ProbeResult?> _raceCandidates(
    List<ProbeCandidate> candidates,
    Map<String, EpisodeTarget> targetByPlugin, {
    required String seedPluginName,
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    _setProbeCandidateOrder(candidates.map((c) => c.pluginName).toList());

    // VideoSourceResolverPool defaults to a single worker; without resizing
    // it the race degenerates to serial resolves.
    _resolverPool.resize(_sourceProbe.concurrency);
    _setProbeProgress(null);
    _startProbePanelTimer(session);
    final result = await _sourceProbe.findFirstPlayable(
      candidates,
      onProgress: (progress) {
        if (!session.isStale) {
          _setProbeProgress(progress);
        }
      },
    );
    // Free any WebView leases still held by candidates that lost the race.
    _probeAdapter.cancelAll();
    _cancelProbePanelTimer();

    if (session.isStale || result == null) {
      return null;
    }

    final winnerName = result.candidate.pluginName;
    final winnerSource = _sourceCandidatesByPlugin[winnerName]!;
    final winnerTarget = targetByPlugin[winnerName]!;

    // Only a win is persisted — a losing candidate says nothing about
    // whether it will fail again next time (see cache module doc comment).
    await _playableSourceCache.put(
      bangumiItem.id,
      PlayableSourceRecord(
        pluginName: winnerName,
        src: winnerSource.src,
        roadIndex: winnerTarget.roadIndex,
        lastGoodAt: DateTime.now(),
      ),
    );

    if (winnerName != seedPluginName) {
      _applyDisplaySource(winnerName, winnerTarget);
      KazumiDialog.showToast(message: '已切换到 $winnerName');
    }

    final roadData = winnerSource.roads[winnerTarget.roadIndex];
    final resolvedEpisode = EpisodeRef.online(
      listIndex: winnerTarget.episodeIndex + 1,
      roadIndex: winnerTarget.roadIndex,
      displayTitle: roadData.identifier[winnerTarget.episodeIndex],
      pageUrl: roadData.data[winnerTarget.episodeIndex],
    );
    _applyResolvedSelection(resolvedEpisode);
    _setOnlineHistoryIdentity(resolvedEpisode);

    await _playProbeWinner(
      result,
      resolvedEpisode,
      offset: winnerTarget.offset.inSeconds,
      session: session,
      playerController: playerController,
    );
    return result;
  }

  /// Recovers from a failed online resolve (timeout, not-found, or any other
  /// resolve error) anywhere after entry — episode switch, road switch, or a
  /// failed play in general — by racing the OTHER sources already known for
  /// this show ([_sourceCandidatesByPlugin]) against the same episode,
  /// remapped per source with [remapForSourceSwap] since episode numbering
  /// isn't stable across plugins. Shares the race with
  /// [beginAutoSourceSelection] via [_raceCandidates]. This is the fix for
  /// the gap described in docs/ideas/source-auto-selection.md: outside of
  /// page entry, a failed resolve used to dead-end on '视频解析超时，请重试'
  /// instead of trying another source.
  ///
  /// Skips straight to the friendly failure widget, with no recovery
  /// attempt, when: the current source was an explicit user pick
  /// ([_currentSourceIsManual]) — a failure there must not silently override
  /// the user's choice — or there is no other known source to try. Exactly
  /// one recovery attempt per failed resolve: a recovery loss never triggers
  /// another recovery.
  Future<void> _recoverFromResolveFailure({
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    if (_currentSourceIsManual) {
      _failAutoSelection('该集数暂时没有可用片源，可能还未收录');
      return;
    }

    final seedPluginName = currentPlugin.name;

    // Entries that arrive with a source already chosen (a resumed history
    // entry) never ran the probe, so nothing has populated the candidate map
    // and there would be nothing to recover to. Search for alternatives now —
    // lazily, so this costs nothing until a resolve actually fails.
    if (_sourceCandidatesByPlugin.length <= 1) {
      _startProbePanelTimer(session);
      final freshResults = await _searchAllPluginsForAutoSelection();
      // Stop the countdown but keep an already-visible panel up: the race
      // below continues the same wait, and hiding here would flicker it.
      _stopProbePanelTimer();
      if (session.isStale) {
        _cancelProbePanelTimer();
        return;
      }
      await _collectSourceCandidates(freshResults);
      if (session.isStale) {
        _cancelProbePanelTimer();
        return;
      }
    }

    final failedTarget = EpisodeTarget(
      roadIndex: selectedEpisode.road,
      episodeIndex: selectedEpisode.episode - 1,
      offset: Duration.zero,
    );

    final targetByPlugin = <String, EpisodeTarget>{};
    final candidates = <ProbeCandidate>[];
    for (final name in _sourceCandidatesByPlugin.keys) {
      if (name == seedPluginName) continue; // already failed, don't retry it
      final source = _sourceCandidatesByPlugin[name]!;
      final target = remapForSourceSwap(
        original: failedTarget,
        targetRoadCount: source.roads.length,
        targetEpisodeCount: _episodeCountFor(source.roads),
        sourceChanged: true,
      );
      if (target.roadIndex >= source.roads.length) continue;
      final roadData = source.roads[target.roadIndex];
      if (target.episodeIndex >= roadData.data.length) continue;
      targetByPlugin[name] = target;
      candidates.add(ProbeCandidate(
        pluginName: name,
        src: source.src,
        episodeUrl:
            source.plugin.buildFullUrl(roadData.data[target.episodeIndex]),
        roadIndex: target.roadIndex,
        useLegacyParser: source.plugin.useLegacyParser,
        httpHeaders: source.plugin.buildHttpHeaders(),
      ));
    }

    if (candidates.isEmpty) {
      // Mirrors beginAutoSourceSelection's empty-candidates exit: the lazy
      // search above may have run long enough to show the panel, so hide it
      // explicitly here too instead of stranding it visible under the
      // failure widget.
      _cancelProbePanelTimer();
      _failAutoSelection('该集数暂时没有可用片源，可能还未收录');
      return;
    }

    final searchValidPlugins = pluginsController.pluginList
        .where((p) => pluginsController.validityTracker.isSearchValid(p.name))
        .map((p) => p.name)
        .toSet();
    final rankedCandidates = rankCandidates(
      available: candidates,
      cached: _playableSourceCache.get(bangumiItem.id),
      searchValidPlugins: searchValidPlugins,
    );

    final result = await _raceCandidates(
      rankedCandidates,
      targetByPlugin,
      seedPluginName: seedPluginName,
      session: session,
      playerController: playerController,
    );

    if (session.isStale) return;

    if (result == null) {
      _failAutoSelection('该集数暂时没有可用片源，可能还未收录');
    }
  }

  Future<void> _playProbeWinner(
    ProbeResult result,
    EpisodeRef resolvedEpisode, {
    required int offset,
    required AsyncSession session,
    required PlayerController playerController,
  }) async {
    _finishLoading();
    KazumiLogger()
        .i('VideoPageController: probe winner ${result.candidate.pluginName}, url ${result.videoUrl}');
    final bool forceAdBlocker = GStorage.getSetting(SettingsKeys.forceAdBlocker);
    final params = PlaybackInitParams(
      videoUrl: result.videoUrl!,
      offset: offset,
      isLocalPlayback: false,
      bangumiId: bangumiItem.id,
      pluginName: currentPlugin.name,
      episode: resolvedEpisode.listIndex,
      danmakuEpisodeNumber: resolvedEpisode.danmakuEpisodeNumber,
      pageUrl: resolvedEpisode.pageUrl,
      sortNumber: resolvedEpisode.sortNumber,
      httpHeaders: result.candidate.httpHeaders,
      adBlockerEnabled: forceAdBlocker || currentPlugin.adBlocker,
      episodeTitle: resolvedEpisode.displayTitle,
      referer: currentPlugin.referer,
      currentRoad: resolvedEpisode.roadIndex,
      coverUrl: bangumiItem.images['large'],
      bangumiName:
          bangumiItem.nameCn.isNotEmpty ? bangumiItem.nameCn : bangumiItem.name,
    );

    final initialized = await playerController.init(params);
    if (session.isActive && initialized) {
      playingEpisode = VideoEpisodeSelection(
        episode: resolvedEpisode.listIndex,
        road: resolvedEpisode.roadIndex,
      );
      unawaited(_loadPlaybackDanmaku(playerController, params, session));
    } else if (session.isActive) {
      _playbackSessions.cancel();
    }
  }

  /// 片源 dropdown manual switch: re-targets the currently selected episode
  /// onto [pluginName]'s own road list (episode numbering isn't stable
  /// across sources, hence the remap) and resolves it the normal
  /// single-source way.
  Future<void> switchToSource(
    String pluginName, {
    required PlayerController playerController,
  }) async {
    if (pluginName == currentPlugin.name) return;
    final target = _sourceCandidatesByPlugin[pluginName];
    if (target == null) return;

    final remapped = remapForSourceSwap(
      original: EpisodeTarget(
        roadIndex: selectedEpisode.road,
        episodeIndex: selectedEpisode.episode - 1,
        offset: Duration.zero,
      ),
      targetRoadCount: target.roads.length,
      targetEpisodeCount: _episodeCountFor(target.roads),
      sourceChanged: true,
    );
    // An explicit dropdown pick — a later resolve failure on it must not be
    // silently auto-swapped away (see [_recoverFromResolveFailure]).
    _currentSourceIsManual = true;
    _applyDisplaySource(pluginName, remapped);
    await changeEpisode(
      remapped.episodeIndex + 1,
      currentRoad: remapped.roadIndex,
      playerController: playerController,
    );
  }

  void _resetEpisodeComments() {
    _commentSessions.cancel();
    episodeInfo.reset();
    episodeCommentsList.clear();
  }

  Future<bool> queryBangumiEpisodeCommentsByID(int id, int episode) async {
    final session = _commentSessions.begin();
    final EpisodeInfo latestEpisodeInfo;
    try {
      latestEpisodeInfo = await BangumiApi.getBangumiEpisodeByID(id, episode);
    } catch (_) {
      if (session.isStale) {
        return false;
      }
      rethrow;
    }
    if (session.isStale) {
      return false;
    }
    final EpisodeCommentResponse value;
    try {
      value =
          await BangumiApi.getBangumiCommentsByEpisodeID(latestEpisodeInfo.id);
    } catch (_) {
      if (session.isStale) {
        return false;
      }
      rethrow;
    }
    if (session.isStale) {
      return false;
    }
    final commentsList = value.commentList;
    if (!isCommentsAscending) {
      commentsList
          .sort((a, b) => b.comment.createdAt.compareTo(a.comment.createdAt));
    } else {
      commentsList
          .sort((a, b) => a.comment.createdAt.compareTo(b.comment.createdAt));
    }
    _applyEpisodeComments(episode, latestEpisodeInfo, commentsList);
    KazumiLogger().i(
        'VideoPageController: loaded comments list length ${episodeCommentsList.length}');
    return true;
  }

  @action
  void _applyEpisodeComments(
    int episode,
    EpisodeInfo info,
    List<EpisodeCommentItem> comments,
  ) {
    commentsEpisode = episode;
    episodeInfo = info;
    episodeCommentsList = ObservableList.of(comments);
  }

  @action
  void toggleSortOrder() {
    isCommentsAscending = !isCommentsAscending;
    episodeCommentsList.sort(
      (a, b) => isCommentsAscending
          ? a.comment.createdAt.compareTo(b.comment.createdAt)
          : b.comment.createdAt.compareTo(a.comment.createdAt),
    );
  }

  /// Called by Modular when the '/video' route scope is disposed.
  @override
  void dispose() {
    _playbackSessions.cancel();
    _danmakuSessions.cancel();
    _commentSessions.cancel();
    _logSubscription?.cancel();
    _logSubscription = null;
    if (!_logStreamController.isClosed) {
      _logStreamController.close();
    }
    final videoSourceService = _videoSourceService;
    _videoSourceService = null;
    if (videoSourceService != null) {
      unawaited(videoSourceService.dispose());
    }
    _probePanelTimer?.cancel();
    _sourceProbe.cancel();
    unawaited(_resolverPool.dispose());
  }

  void enterFullScreen() {
    isFullscreen = true;
    DisplayModeService.enterFullScreen(lockOrientation: false);
  }

  void exitFullScreen() {
    isFullscreen = false;
    DisplayModeService.exitFullScreen();
  }

  void isDesktopFullscreen() async {
    if (isDesktop()) {
      isFullscreen = await windowManager.isFullScreen();
    }
  }

  void handleOnEnterFullScreen() async {
    isFullscreen = true;
  }

  void handleOnExitFullScreen() async {
    isFullscreen = false;
  }
}

class OfflineRoadListSnapshot {
  const OfflineRoadListSnapshot({
    required this.roads,
    required this.episodesByNumber,
    required this.displayRoadToOriginalRoad,
    required this.originalRoadToDisplayRoad,
  });

  final List<Road> roads;
  final Map<int, DownloadEpisode> episodesByNumber;
  final Map<int, int> displayRoadToOriginalRoad;
  final Map<int, int> originalRoadToDisplayRoad;
}

OfflineRoadListSnapshot buildOfflineRoadListSnapshot(
  List<DownloadEpisode> episodes,
) {
  final groupedEpisodes = <int, List<DownloadEpisode>>{};
  final episodesByNumber = <int, DownloadEpisode>{};

  for (final episode in episodes) {
    episodesByNumber[episode.episodeNumber] = episode;
    groupedEpisodes.putIfAbsent(episode.road, () => []).add(episode);
  }

  final originalRoads = groupedEpisodes.keys.toList()..sort();
  final roads = <Road>[];
  final displayRoadToOriginalRoad = <int, int>{};
  final originalRoadToDisplayRoad = <int, int>{};

  for (final originalRoad in originalRoads) {
    final roadEpisodes = groupedEpisodes[originalRoad]!
      ..sort((a, b) => a.episodeNumber.compareTo(b.episodeNumber));
    final displayRoad = roads.length;
    displayRoadToOriginalRoad[displayRoad] = originalRoad;
    originalRoadToDisplayRoad[originalRoad] = displayRoad;
    roads.add(Road(
      name: originalRoad >= 0
          ? '播放列表${originalRoad + 1}'
          : '播放列表${displayRoad + 1}',
      data: roadEpisodes.map((e) => e.episodeNumber.toString()).toList(),
      identifier: roadEpisodes
          .map((e) =>
              e.episodeName.isNotEmpty ? e.episodeName : '第${e.episodeNumber}集')
          .toList(),
    ));
  }

  return OfflineRoadListSnapshot(
    roads: roads,
    episodesByNumber: episodesByNumber,
    displayRoadToOriginalRoad: displayRoadToOriginalRoad,
    originalRoadToDisplayRoad: originalRoadToDisplayRoad,
  );
}

/// One source's chapter-road result, gathered during automatic
/// playable-source selection (stage 2, pure HTTP).
class _SourceCandidate {
  const _SourceCandidate({
    required this.plugin,
    required this.src,
    required this.title,
    required this.roads,
  });

  final Plugin plugin;
  final String src;
  final String title;
  final List<Road> roads;
}

class EpisodeRef {
  const EpisodeRef({
    required this.listIndex,
    required this.roadIndex,
    required this.displayTitle,
    required this.pageUrl,
    required this.sortNumber,
    required this.historyEpisodeNumber,
    required this.danmakuEpisodeNumber,
    required this.originalRoadIndex,
  });

  final int listIndex;
  final int roadIndex;
  final String displayTitle;
  final String pageUrl;

  /// Episode sort number.
  /// - Online: parsed from [displayTitle] via [extractEpisodeNumber];
  ///   null when unparsable.
  /// - Offline: always the download record's episodeNumber.
  final int? sortNumber;
  final int historyEpisodeNumber;
  final int danmakuEpisodeNumber;
  final int originalRoadIndex;

  factory EpisodeRef.online({
    required int listIndex,
    required int roadIndex,
    required String displayTitle,
    required String pageUrl,
  }) {
    final parsedEpisodeNumber = extractEpisodeNumber(displayTitle);
    return EpisodeRef(
      listIndex: listIndex,
      roadIndex: roadIndex,
      displayTitle: displayTitle,
      pageUrl: pageUrl,
      sortNumber: parsedEpisodeNumber > 0 ? parsedEpisodeNumber : null,
      historyEpisodeNumber: listIndex,
      danmakuEpisodeNumber:
          parsedEpisodeNumber > 0 ? parsedEpisodeNumber : listIndex,
      originalRoadIndex: roadIndex,
    );
  }

  const factory EpisodeRef.offline({
    required int listIndex,
    required int roadIndex,
    required String displayTitle,
    required String pageUrl,
    required int episodeNumber,
    required int originalRoadIndex,
  }) = _OfflineEpisodeRef;
}

class _OfflineEpisodeRef extends EpisodeRef {
  const _OfflineEpisodeRef({
    required super.listIndex,
    required super.roadIndex,
    required super.displayTitle,
    required super.pageUrl,
    required int episodeNumber,
    required super.originalRoadIndex,
  }) : super(
          sortNumber: episodeNumber,
          historyEpisodeNumber: episodeNumber,
          danmakuEpisodeNumber: episodeNumber,
        );
}
