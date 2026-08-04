// Drives the REAL Kazumi macOS app (compiled build, real network, real
// WebViews) to get LIVE proof of a just-fixed bug: fork builds compile with
// an empty KAZUMI_APPID (String.fromEnvironment with no --dart-define), and
// the Bangumi mirror rewrite used to unconditionally send search traffic to
// api.kazumi.fyi, which 401'd with no AppId. The fix (see
// lib/request/core/dio_factory.dart's resolveBangumiMirrorPath) now returns
// null -- i.e. "don't mirror" -- whenever mirrorAppId is empty, so requests
// fall through to direct api.bgm.tv instead. Unit tests already cover the
// pure function; this test proves the guard actually fires inside the fully
// assembled app and that search results keep flowing end to end.
//
// Two stages:
//   Stage S (search)  -- HARD assertions. This is what verifies the fix:
//                         searching a real, very recently aired show
//                         (尼古喵喵, bgm.tv subject 622206, July 2026) must
//                         return it. An empty result here means the guard
//                         does not work in the assembled app -- api.bgm.tv
//                         was confirmed reachable from this machine minutes
//                         before this test was written.
//   Stage P (play)     -- our own invariants are hard (bounded termination,
//                         exactly one of two terminal states, the old
//                         dead-end string never appears); remote source
//                         availability is soft. A brand-new show may
//                         genuinely not be carried by any installed plugin
//                         yet -- that is an expected, printed outcome, not a
//                         test failure (this repo's own convention for dead
//                         /uncarried sources).
//
// Run with:
//   export PATH="$HOME/develop/flutter/bin:$PATH"
//   flutter test integration_test/search_and_play_test.dart -d macos
//
// This test hits REAL bgm.tv search traffic and REAL third-party scraper
// sites, through the user's real installed plugins (copied -- never moved
// -- into an isolated Hive/storage directory, so this run never touches the
// real app's history, collection, or settings; see
// _seedIsolatedPluginDirectory and _IsolatedPathProviderPlatform below,
// copied verbatim from integration_test/auto_source_selection_test.dart).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kazumi/main.dart' as app;
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/index_page.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/search/search_controller.dart';
import 'package:kazumi/pages/search/search_page.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// The show searched for in Stage S. bgm.tv subject 622206, a July 2026
/// show -- recent enough that it can only have been returned by a live
/// api.bgm.tv (or a working mirror), never by any cached/bundled fixture.
const _targetNameCn = '尼古喵喵';

/// Old dead-end string on the auto-selection path (video_controller.dart's
/// _resolveWithVideoSourceService, VideoSourceTimeoutException branch),
/// copied verbatim from integration_test/auto_source_selection_test.dart so
/// both tests are guarding the exact same literal.
const _deadEndString = '视频解析超时，请重试';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'search (live api.bgm.tv via mirror-guard fix) then play the result',
    (tester) async {
      final tempDir =
          await Directory.systemTemp.createTemp('kazumi_integration_test_');
      addTearDown(() async {
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      });

      final supportDir = Directory('${tempDir.path}/support');
      final scratchDir = Directory('${tempDir.path}/tmp');
      await supportDir.create(recursive: true);
      await scratchDir.create(recursive: true);

      final pluginCount = await _seedIsolatedPluginDirectory(supportDir.path);

      PathProviderPlatform.instance =
          _IsolatedPathProviderPlatform(supportDir.path, scratchDir.path);

      print('[setup] Isolated app-support dir: ${supportDir.path}');
      print('[setup] Seeded with $pluginCount plugin rule file(s). Real app '
          'history/collection/settings are untouched by this run.');

      // ---------------------------------------------------------------
      // Boot the REAL app (lib/main.dart's main()) against the isolated
      // storage above.
      // ---------------------------------------------------------------
      app.main();
      await tester.pump();

      final booted = await _pumpUntil(
        tester,
        () => find.byType(IndexPage).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      if (!booted) {
        fail(
          'App did not reach the tab shell (IndexPage) within 60s after '
          'boot. This usually means plugin seeding failed '
          '(pluginCount=$pluginCount) and the app fell through to '
          '/onboarding instead of the default startup page.',
        );
      }
      print('[setup] App booted to the tab shell.');

      final homeContext = tester.element(find.byType(IndexPage));

      // ================================================================
      // Stage S: search (HARD assertions -- this is what proves the fix
      // live).
      // ================================================================
      homeContext.pushNamed('/search/');
      final onSearchPage = await _pumpUntil(
        tester,
        () => find.byType(SearchPage).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 15),
      );
      if (!onSearchPage) {
        fail('SearchPage did not render within 15s of pushNamed(\'/search/\').');
      }
      print('[S] SearchPage reached.');

      final searchPageController =
          tester.element(find.byType(SearchPage)).read<SearchPageController>();

      // ---- Preconditions: this run must actually reproduce the
      // previously-broken fork configuration, or a pass here proves
      // nothing. ----
      const kazumiAppId = String.fromEnvironment('KAZUMI_APPID');
      print('[S] Precondition: KAZUMI_APPID (compiled in) is '
          '${kazumiAppId.isEmpty ? "empty" : "non-empty"}.');
      expect(
        kazumiAppId,
        isEmpty,
        reason: 'This run must be built with an empty KAZUMI_APPID (the '
            'fork\'s real, historically-broken configuration) or a passing '
            'search result here would not actually exercise the mirror-guard '
            'fix at all.',
      );

      final mirrorEnabled =
          GStorage.getSetting(SettingsKeys.enableBangumiProxy);
      print('[S] Precondition: enableBangumiProxy setting = $mirrorEnabled.');
      expect(
        mirrorEnabled,
        isTrue,
        reason: 'enableBangumiProxy defaults to true; if the isolated '
            'storage somehow has it false, resolveBangumiMirrorPath would '
            'short-circuit on proxyEnabled before ever reaching the '
            'mirrorAppId.isEmpty guard this test exists to exercise, and a '
            'passing search would not prove the fix works.',
      );

      await searchPageController.searchBangumi(_targetNameCn, type: 'init');
      await tester.pump();

      expect(
        searchPageController.isTimeOut,
        isFalse,
        reason: 'api.bgm.tv was confirmed reachable from this machine '
            'minutes before this test was written -- isTimeOut=true here '
            'means the mirror-guard fix does NOT work in the assembled '
            'app.',
      );
      expect(
        searchPageController.bangumiList,
        isNotEmpty,
        reason: 'Empty search results for a real, recently-aired show '
            'means the mirror-guard fix does NOT work in the assembled '
            'app (search traffic either 401\'d against the mirror or '
            'otherwise failed).',
      );

      BangumiItem? matchedItem;
      for (final item in searchPageController.bangumiList) {
        if (item.nameCn == _targetNameCn) {
          matchedItem = item;
          break;
        }
      }
      expect(
        matchedItem,
        isNotNull,
        reason: 'Search results were non-empty but none had '
            'nameCn == "$_targetNameCn" -- printing the full result list '
            'would be the next debugging step. Got: '
            '${searchPageController.bangumiList.map((i) => "${i.id}:${i.nameCn}").toList()}',
      );
      print('[S] Matched item: id=${matchedItem!.id}, '
          'nameCn=${matchedItem.nameCn} (expected id 622206, printed not '
          'asserted).');

      final cardRendered = await _pumpUntil(
        tester,
        () => find.text(_targetNameCn).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10),
      );
      if (!cardRendered) {
        fail('Result card for "$_targetNameCn" never rendered within 10s '
            'of a non-empty bangumiList.');
      }
      print('[S] PASS: search returned ${searchPageController.bangumiList.length} '
          'result(s) via live api.bgm.tv (mirror-guard fix verified live); '
          'result card for "$_targetNameCn" rendered.');

      // ================================================================
      // Stage P: play the searched result (our invariants hard, remote
      // availability soft).
      // ================================================================
      await tester.tap(find.text(_targetNameCn).first);
      await tester.pump();

      var onInfoPage = await _pumpUntil(
        tester,
        () => find.text('开始观看').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 20),
      );
      if (!onInfoPage) {
        print('[P] Tap on the result card did not reach InfoPage within '
            '20s; falling back to pushNamed(\'/info/\', arguments: '
            'matchedItem).');
        homeContext.pushNamed('/info/', arguments: matchedItem);
        onInfoPage = await _pumpUntil(
          tester,
          () => find.text('开始观看').evaluate().isNotEmpty,
          timeout: const Duration(seconds: 20),
        );
      }
      if (!onInfoPage) {
        fail('InfoPage did not render the 开始观看 FAB within 20s, even '
            'after the pushNamed(\'/info/\') fallback.');
      }
      print('[P] InfoPage reached; 开始观看 FAB present.');

      // Give the info page's background plugin search a head start,
      // mirroring integration_test/auto_source_selection_test.dart.
      await tester.pump(const Duration(seconds: 4));

      await tester.tap(find.text('开始观看'));
      await tester.pump();

      final onPlayer = await _pumpUntil(
        tester,
        () => find.byType(GridView).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 20),
      );
      if (!onPlayer) {
        fail('Did not land on the player (no GridView found) within 20s of '
            'tapping 开始观看.');
      }
      print('[P] Player reached (episode GridView present).');

      final videoPageContext = tester.element(find.byType(GridView).first);
      final videoPageController = videoPageContext.read<VideoPageController>();
      final playerController = videoPageContext.read<PlayerController>();

      // ---- Bounded auto-selection poll, mirroring
      // auto_source_selection_test.dart's I3 loop. ----
      const totalBudget = Duration(seconds: 120);
      const step = Duration(milliseconds: 300);
      final deadline = DateTime.now().add(totalBudget);
      final raceStartedAt = DateTime.now();

      bool terminal() =>
          videoPageController.playingEpisode != null ||
          (videoPageController.errorMessage != null &&
              videoPageController.probeExhausted);

      while (!terminal() && DateTime.now().isBefore(deadline)) {
        await tester.pump(step);
        expect(
          find.text(_deadEndString),
          findsNothing,
          reason: 'The old dead-end string ("$_deadEndString") must never '
              'appear on the auto-selection path -- a broken source must '
              'not be a dead end.',
        );
      }

      final reachedTerminal = terminal();
      final elapsedMs =
          DateTime.now().difference(raceStartedAt).inMilliseconds;

      expect(
        reachedTerminal,
        isTrue,
        reason: 'Auto-selection must terminate within '
            '${totalBudget.inSeconds}s in exactly one of two states '
            '(playback started, or the friendly failure widget) -- never '
            'an infinite spinner. State after ${totalBudget.inSeconds}s: '
            'loading=${videoPageController.loading}, '
            'errorMessage=${videoPageController.errorMessage}, '
            'probeExhausted=${videoPageController.probeExhausted}, '
            'playingEpisode=${videoPageController.playingEpisode}',
      );

      final playbackStarted = videoPageController.playingEpisode != null;
      final failedGracefully = videoPageController.errorMessage != null &&
          videoPageController.probeExhausted;

      expect(
        playbackStarted ^ failedGracefully,
        isTrue,
        reason: 'Must land in EXACTLY ONE of the two terminal states, not '
            'both/neither. playbackStarted=$playbackStarted, '
            'failedGracefully=$failedGracefully',
      );

      print('[P] Auto-selection terminated after ${elapsedMs}ms (budget '
          '${totalBudget.inSeconds}s).');

      var playbackAdvanced = false;
      if (playbackStarted) {
        final winningPlugin = videoPageController.currentPlugin.name;
        print('[P] PLAYBACK STARTED via plugin: $winningPlugin');

        final positions = <Duration>[];
        for (var i = 0; i < 8; i++) {
          await tester.pump(const Duration(seconds: 1));
          final playing = playerController.playback.playing;
          final loading = playerController.playback.loading;
          final position = playerController.playback.currentPosition;
          positions.add(position);
          print('[P] sample t=+${i + 1}s: playing=$playing, '
              'loading=$loading, position=$position');
        }
        playbackAdvanced = positions.isNotEmpty &&
            positions.last > positions.first;
        print('[P] Position advanced across the 8s sampling window: '
            '$playbackAdvanced (first=${positions.isNotEmpty ? positions.first : null}, '
            'last=${positions.isNotEmpty ? positions.last : null})');

        // If the stream never actually rolled, the winner is a source that
        // passed both probe gates and still cannot play (observed live: a
        // real mp4 whose CDN stalled the read). That is exactly what
        // recoverFromPlaybackStartFailure exists to rescue, and it only
        // fires ~2s after the player's error -- i.e. right around when the
        // window above ends. Keep watching so a swap is actually observable
        // instead of being cut off mid-recovery.
        if (!playbackAdvanced) {
          print('[P] Stream never rolled -- watching for automatic source '
              'recovery (the swap fires ~2s after the player error).');
          const recoveryBudget = Duration(seconds: 100);
          final recoveryDeadline = DateTime.now().add(recoveryBudget);
          while (DateTime.now().isBefore(recoveryDeadline)) {
            await tester.pump(const Duration(seconds: 5));
            final nowPlugin = videoPageController.currentPlugin.name;
            final position = playerController.playback.currentPosition;
            print('[P] recovery watch: plugin=$nowPlugin, '
                'position=$position, loading=${videoPageController.loading}, '
                'errorMessage=${videoPageController.errorMessage}');
            if (position > Duration.zero) {
              playbackAdvanced = true;
              print('[P] RECOVERED: playback is advancing on $nowPlugin.');
              break;
            }
            if (videoPageController.errorMessage != null &&
                videoPageController.probeExhausted) {
              print('[P] Recovery ran out of sources and surfaced the '
                  'friendly failure widget -- bounded, not a hang.');
              break;
            }
          }
          if (videoPageController.currentPlugin.name != winningPlugin) {
            print('[P] Source was auto-swapped: $winningPlugin -> '
                '${videoPageController.currentPlugin.name}');
          } else {
            print('[P] Source was NOT swapped away from $winningPlugin.');
          }
        }
      } else {
        print('[P] NO SOURCE (graceful failure) -- brand-new shows may '
            'genuinely not be carried by any installed plugin yet; this is '
            'a soft/expected outcome, not a test failure.');
        print('[P] errorMessage="${videoPageController.errorMessage}"');
        print('[P] probeCandidateOrder: '
            '${videoPageController.probeCandidateOrder.toList()}');
        print('[P] probeCompletedOrder: '
            '${videoPageController.probeCompletedOrder.toList()}');
      }

      // ================================================================
      // Final summary.
      // ================================================================
      print('SEARCH: PASS (id=${matchedItem.id}, name=${matchedItem.nameCn})');
      if (playbackStarted) {
        print('PLAYBACK: STARTED via ${videoPageController.currentPlugin.name} '
            '(position advanced: ${playbackAdvanced ? "yes" : "no"})');
      } else {
        print('PLAYBACK: NO SOURCE (graceful)');
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

/// Polls [condition] by pumping [tester] every [step] until it is true or
/// [timeout] elapses. Returns whether [condition] was met.
///
/// Deliberately never uses pumpAndSettle: several widgets on this journey
/// (indeterminate CircularProgressIndicator spinners while resolving,
/// skeleton shimmer elsewhere in the app) animate continuously while real
/// network calls are in flight, which would make pumpAndSettle spin until
/// its own internal timeout instead of reflecting real progress.
Future<bool> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  required Duration timeout,
  Duration step = const Duration(milliseconds: 300),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      return condition();
    }
    await tester.pump(step);
  }
  return true;
}

/// Copies the real app's installed plugin rule files into the isolated
/// storage directory this test boots against, so the player race has real,
/// user-installed sources to probe instead of none. Falls back to the
/// bundled assets/plugins/*.json defaults if the real app's storage can't
/// be found, e.g. on a machine that has never run Kazumi.
///
/// This only ever READS the real app's plugins.json -- never writes to
/// it -- and the isolated copy this test actually runs against means real
/// history/collection/settings are never touched by this test.
Future<int> _seedIsolatedPluginDirectory(String supportDirPath) async {
  final v2Dir = Directory('$supportDirPath/plugins/v2');
  await v2Dir.create(recursive: true);
  final target = File('${v2Dir.path}/plugins.json');

  try {
    final realSupportDir = await getApplicationSupportDirectory();
    final realPluginsFile =
        File('${realSupportDir.path}/plugins/v2/plugins.json');
    if (await realPluginsFile.exists()) {
      final raw = await realPluginsFile.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      await target.writeAsString(raw);
      print('[setup] Seeded isolated plugin storage from the real app\'s '
          '${realPluginsFile.path} (${list.length} real installed '
          'plugin(s)) -- read only, real storage untouched.');
      return list.length;
    }
    print('[setup] Real app plugin storage not found at '
        '${realPluginsFile.path}; falling back to bundled '
        'assets/plugins/*.json defaults.');
  } catch (e) {
    print('[setup] Could not read real app plugin storage ($e); falling '
        'back to bundled assets/plugins/*.json defaults.');
  }

  final dir = Directory('assets/plugins');
  final plugins = <Map<String, dynamic>>[];
  if (await dir.exists()) {
    for (final entity in dir.listSync()) {
      if (entity is File && entity.path.endsWith('.json')) {
        plugins.add(
          jsonDecode(await entity.readAsString()) as Map<String, dynamic>,
        );
      }
    }
  }
  await target.writeAsString(jsonEncode(plugins));
  print('[setup] Seeded isolated plugin storage with ${plugins.length} '
      'bundled default plugin(s).');
  return plugins.length;
}

/// Points path_provider at the isolated temp directory created for this
/// test run instead of the real device Application Support directory, so
/// the real app's history, collection, and settings are never touched.
/// Copied verbatim from integration_test/auto_source_selection_test.dart.
class _IsolatedPathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _IsolatedPathProviderPlatform(this._supportPath, this._tempPath);
  final String _supportPath;
  final String _tempPath;

  @override
  Future<String?> getApplicationSupportPath() async => _supportPath;

  @override
  Future<String?> getTemporaryPath() async => _tempPath;

  // Not directly used by lib/ (only getApplicationSupportDirectory and
  // getTemporaryDirectory are), but hive_ce_flutter's Hive.initFlutter
  // calls getApplicationDocumentsDirectory() internally to compute a base
  // path even though main.dart passes it an already-absolute subDir that
  // overrides it (package:path's join() discards everything before an
  // absolute segment) -- so this still needs to resolve without throwing.
  // The rest are overridden defensively for the same reason: real
  // MockPlatformInterfaceMixin methods throw UnimplementedError, and this
  // test boots the FULL real app, which pulls in more plugins than a
  // narrower harness would.
  @override
  Future<String?> getApplicationDocumentsPath() async => '$_supportPath/documents';

  @override
  Future<String?> getLibraryPath() async => '$_supportPath/library';

  @override
  Future<String?> getApplicationCachePath() async => '$_tempPath/cache';

  @override
  Future<String?> getDownloadsPath() async => '$_tempPath/downloads';
}
