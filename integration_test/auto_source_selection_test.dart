// Drives the REAL Kazumi macOS app (compiled build, real WebViews, real
// network) to verify the automatic playable-source selection feature (see
// docs/ideas/source-auto-selection.md). Automates the tier-2 "Live
// Verification" cases that doc marks manual-only:
//   I1 -> M1 (journey change: 开始观看 goes straight to the player)
//   I2 -> M7 (手动选择 still reaches the full SourceSheet)
//   I3 -> M1/M2 (bounded termination, exactly one of two terminal states,
//                the old dead-end string never appears)
//   I4 -> M5/M6 (progress panel timing: no instant flash, no flicker)
//
// Run with:
//   export PATH="$HOME/develop/flutter/bin:$PATH"
//   flutter test integration_test/auto_source_selection_test.dart -d macos
//
// This test hits REAL third-party scraper sites, through the user's real
// installed plugins (copied -- never moved -- into an isolated Hive/storage
// directory, so this run never touches the real app's history, collection,
// or settings; see _seedIsolatedPluginDirectory and
// _IsolatedPathProviderPlatform below). A dead source is NOT a test
// failure: only this feature's OWN invariants are asserted (bounded
// termination, the two-state outcome, absence of the old dead-end string,
// the manual escape hatch surviving, no progress-panel flicker).
// Everything about which source won, timings, and remote availability is
// printed, not asserted -- mirroring test/live/live_source_verification_test.dart's
// own rules for this repo's live suite.
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
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Same target used by test/live/live_source_verification_test.dart -- long
/// running, popular, and (per that suite's last recorded live run) actually
/// carried by this install's real plugins, so the race has something real
/// to find.
const _targetNameCn = '间谍过家家';
const _targetNameRomaji = 'SPY×FAMILY';

/// Old dead-end string this feature replaces
/// (video_controller.dart's _resolveWithVideoSourceService,
/// VideoSourceTimeoutException branch). Auto-selection routes failures
/// through _failAutoSelection instead, so this must never appear on the
/// auto-selection path.
const _deadEndString = '视频解析超时，请重试';

/// The friendly failure widget's fixed message
/// (video_page.dart's _buildAllSourcesFailedWidget) -- shown whenever
/// probeExhausted is true, regardless of which of the two internal
/// _failAutoSelection messages ('未找到可播放的片源' or
/// '该集数暂时没有可用片源，可能还未收录') was actually set.
const _friendlyFailureString = '该集数暂时没有可用片源，可能还未收录';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'automatic playable-source selection: M1/M2/M5/M6/M7 live verification',
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
      // main() is declared `void main() async` (not `Future<void>`), so it
      // can't be awaited directly -- fire it and rely on the pump loop
      // below to observe when boot has actually reached the tab shell.
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

      final bangumiItem = _fixtureBangumiItem();
      final homeContext = tester.element(find.byType(IndexPage));

      // ---------------------------------------------------------------
      // Navigate to the info page exactly the way BangumiCard.onTap does it
      // (bean/card/bangumi_card.dart): context.pushNamed('/info/',
      // arguments: bangumiItem). A constructed fixture is used instead of
      // driving the search UI so this run's network surface is limited to
      // the plugin (third-party scraper) side -- the actual subject under
      // test -- instead of also depending on bgm.tv.
      // ---------------------------------------------------------------
      homeContext.pushNamed('/info/', arguments: bangumiItem);
      final onInfoPage = await _pumpUntil(
        tester,
        () => find.text('开始观看').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 20),
      );
      if (!onInfoPage) {
        fail('InfoPage did not render the 开始观看 FAB within 20s.');
      }
      print('[I1] InfoPage reached; 开始观看 FAB present.');

      // Give the info page's background plugin search
      // (PluginSearchService.queryAllSource, kicked off from
      // InfoPage.initState) a head start, mirroring a user reading the
      // synopsis before tapping play -- and meaning the player is more
      // likely to start from a non-empty snapshot instead of paying for
      // its own full re-search (docs/ideas/source-auto-selection.md's
      // "cold search" fallback path).
      await tester.pump(const Duration(seconds: 4));

      // ================================================================
      // I1 (M1): 开始观看 must go STRAIGHT to the player -- no SourceSheet.
      // ================================================================
      expect(
        find.text('选择播放源'),
        findsNothing,
        reason: 'SourceSheet must not be open before 开始观看 is even tapped',
      );

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
      expect(
        find.text('选择播放源'),
        findsNothing,
        reason: 'I1/M1: 开始观看 must navigate straight to the player -- the '
            'SourceSheet ("选择播放源") must never open on this path',
      );
      print('[I1] PASS: 开始观看 navigated straight to the player route; '
          'episode grid is present; SourceSheet header ("选择播放源") is '
          'absent. M1 journey change verified.');

      // VideoPageController/PlayerController are PAGE-SCOPED binds
      // (video_module.dart's `provide:`), built in a page-local injector
      // and exposed via an InheritedWidget -- reachable through
      // context.read<T>() from inside the page's subtree, NOT through the
      // global inject<T>() (which only sees module-level binds; confirmed
      // by flutter_modular's own state/scoped.dart doc comments).
      final videoPageContext = tester.element(find.byType(GridView).first);
      final videoPageController = videoPageContext.read<VideoPageController>();
      final playerController = videoPageContext.read<PlayerController>();

      // ================================================================
      // I4 part 1 (M5): the progress panel must not flash instantly.
      // ================================================================
      expect(
        videoPageController.showSourceSelectionPanel,
        isFalse,
        reason: 'I4/M5: the progress panel must not be visible immediately '
            'after entering the player (a fast race must never flash it)',
      );
      print('[I4] Progress panel absent immediately after entering the '
          'player (pre-3s threshold) -- OK.');

      // ================================================================
      // I3 (M1/M2) + I4 part 2 (M6): poll until auto-selection terminates,
      // watching for the dead-end string and for panel flicker along the
      // way.
      // ================================================================
      const totalBudget = Duration(seconds: 90);
      const step = Duration(milliseconds: 300);
      final deadline = DateTime.now().add(totalBudget);
      final visibilitySamples = <bool>[];
      var lastPanelState = false;
      DateTime? panelFirstSeenAt;
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
          reason: 'I3: the old dead-end string ("$_deadEndString") must '
              'never appear on the auto-selection path -- a broken source '
              'must not be a dead end',
        );

        final visible = videoPageController.showSourceSelectionPanel;
        visibilitySamples.add(visible);
        if (visible && !lastPanelState) {
          panelFirstSeenAt ??= DateTime.now();
          print('[I4] Progress panel appeared at +'
              '${DateTime.now().difference(raceStartedAt).inMilliseconds}ms');
        }
        lastPanelState = visible;
      }

      final reachedTerminal = terminal();
      final elapsedMs =
          DateTime.now().difference(raceStartedAt).inMilliseconds;

      // ---- I3's headline assertion: bounded termination, never an
      // infinite spinner. ----
      expect(
        reachedTerminal,
        isTrue,
        reason: 'I3/M1/M2: auto-selection must terminate within '
            '${totalBudget.inSeconds}s in exactly one of two states '
            '(playback started, or the friendly failure widget) -- it must '
            'never be left on an infinite spinner. State after '
            '${totalBudget.inSeconds}s: '
            'loading=${videoPageController.loading}, '
            'errorMessage=${videoPageController.errorMessage}, '
            'probeExhausted=${videoPageController.probeExhausted}, '
            'playingEpisode=${videoPageController.playingEpisode}',
      );

      final playbackStarted = videoPageController.playingEpisode != null;
      final failedGracefully = videoPageController.errorMessage != null &&
          videoPageController.probeExhausted;

      // Exactly one of the two terminal states (structurally guaranteed by
      // _finishLoading/_failAutoSelection being the controller's only two
      // terminal transitions -- asserted here as a live check too).
      expect(
        playbackStarted ^ failedGracefully,
        isTrue,
        reason: 'I3: must land in EXACTLY ONE of the two terminal states, '
            'not both/neither. playbackStarted=$playbackStarted, '
            'failedGracefully=$failedGracefully',
      );

      print('[I3] PASS: auto-selection terminated after ${elapsedMs}ms '
          '(budget ${totalBudget.inSeconds}s). Outcome: '
          '${playbackStarted ? "PLAYBACK STARTED" : "FRIENDLY FAILURE"}.');
      if (playbackStarted) {
        print('[I3] Winning source: '
            '${videoPageController.currentPlugin.name}, '
            'playing=${playerController.playback.playing}, '
            'loading=${playerController.playback.loading}');
      } else {
        print('[I3] errorMessage="${videoPageController.errorMessage}"');
      }
      print('[I3] Probe candidate order: '
          '${videoPageController.probeCandidateOrder.toList()}');
      print('[I3] Probe completed order: '
          '${videoPageController.probeCompletedOrder.toList()}');

      if (failedGracefully) {
        await tester.pump();
        expect(
          find.text(_friendlyFailureString),
          findsOneWidget,
          reason: 'I3: the friendly failure widget must show '
              '"$_friendlyFailureString" '
              '(video_page.dart\'s _buildAllSourcesFailedWidget)',
        );
        for (final actionText in const [
          '换一条播放线路',
          '手动选择片源',
          '选择其他分集',
        ]) {
          expect(
            find.text(actionText),
            findsOneWidget,
            reason: 'I3: the friendly failure widget must offer all three '
                'recovery actions ($actionText missing)',
          );
        }
        print('[I3] Friendly failure widget verified: message + all three '
            'recovery actions (换一条播放线路 / 手动选择片源 / 选择其他分集) '
            'present.');
      }

      // ---- I4's flicker assertion (M6) ----
      final sawPanel = visibilitySamples.any((v) => v);
      if (sawPanel) {
        var reappearances = 0;
        for (var i = 1; i < visibilitySamples.length; i++) {
          if (!visibilitySamples[i - 1] && visibilitySamples[i]) {
            reappearances++;
          }
        }
        expect(
          reappearances,
          equals(1),
          reason: 'I4/M6: the progress panel must appear once and not '
              'flicker (disappear and reappear) while the race is still in '
              'progress. Observed $reappearances appear-transitions across '
              '${visibilitySamples.length} samples.',
        );
        final firstSeenMs =
            panelFirstSeenAt?.difference(raceStartedAt).inMilliseconds;
        print('[I4] PASS (M6 exercised): progress panel appeared once '
            '(first seen at +${firstSeenMs}ms) and did not flicker across '
            '${visibilitySamples.length} samples.');
      } else {
        print('[I4] M6 NOT exercised: the race finished (elapsedMs='
            '$elapsedMs) before the 3s panel threshold ever elapsed, so '
            'there was nothing to flicker. This is a pass by M5\'s own '
            'definition (the panel never appears for a fast race), not a '
            'vacuous assertion.');
      }

      // ================================================================
      // I2 (M7): the 片源 dropdown's 手动选择 entry must still reach the
      // full SourceSheet.
      // ================================================================
      // sourceMenuAnchor's TextButton label is `'$currentSourceName '` (or
      // '片源 ' before any source is picked) -- video_page.dart's
      // sourceMenuAnchor. Located by that exact label rather than
      // find.byType(MenuAnchor).first: the player has more than one
      // MenuAnchor (this dropdown and the 播放线路 one), and byType's
      // traversal order does not reliably match visual/source order across
      // Stack layers, so "first" is not guaranteed to be this one.
      final sourceNames = videoPageController.availableSourceNames.toList();
      print('[I2] 片源 dropdown available source name(s): $sourceNames');
      final currentSourceLabel = videoPageController.currentPlugin.name.isEmpty
          ? '片源 '
          : '${videoPageController.currentPlugin.name} ';
      final sourceAnchorButton =
          find.widgetWithText(TextButton, currentSourceLabel);
      expect(
        sourceAnchorButton,
        findsOneWidget,
        reason: 'I2/M7: the 片源 dropdown must be present in the player '
            'regardless of auto-selection outcome (looked for a TextButton '
            'labelled "$currentSourceLabel")',
      );
      await tester.tap(sourceAnchorButton);
      final menuOpen = await _pumpUntil(
        tester,
        () => find.text('手动选择').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10),
      );
      expect(
        menuOpen,
        isTrue,
        reason: 'I2/M7: the 片源 dropdown must list a 手动选择 entry',
      );
      print('[I2] 片源 dropdown opened; 手动选择 entry present.');

      await tester.tap(find.text('手动选择'));
      final sheetOpen = await _pumpUntil(
        tester,
        () => find.text('选择播放源').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 10),
      );
      expect(
        sheetOpen,
        isTrue,
        reason: 'I2/M7: 手动选择 must open the full SourceSheet '
            '("选择播放源" header)',
      );
      print('[I2] PASS: 手动选择 opened the full SourceSheet ("选择播放源" '
          'header present). Escape hatch survived.');

      // Best-effort, NOT a hard requirement: whether 别名检索/手动检索 have
      // actually rendered yet depends on the sheet's own fresh plugin
      // search (SourceSheet.initState kicks off its own queryAllSource)
      // resolving for whichever plugin tab is currently built -- i.e. on
      // remote availability/timing, which per this harness's own rules
      // (see file header) is printed, not asserted on.
      final foundAliasEntry = await _pumpUntil(
        tester,
        () => find.text('别名检索').evaluate().isNotEmpty ||
            find.text('手动检索').evaluate().isNotEmpty,
        timeout: const Duration(seconds: 25),
      );
      if (foundAliasEntry) {
        print('[I2] 别名检索/手动检索 affordances reachable on the initial '
            'plugin tab.');
      } else {
        print('[I2] 别名检索/手动检索 not yet rendered on the initial plugin '
            'tab within 25s (depends on that plugin\'s own live search '
            'settling). SourceSheet itself is confirmed open above, which '
            'is the structural escape-hatch guarantee this case exists to '
            'prove; not asserting further on remote search timing.');
      }
    },
    timeout: const Timeout(Duration(minutes: 6)),
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

/// Fully populated so InfoPage's `_needsBangumiInfoRefresh` is false and it
/// never calls out to bgm.tv -- this harness's network surface is
/// deliberately limited to the plugin (third-party scraper) side, which is
/// the actual subject under test. The id is a synthetic value; isolated
/// storage means there is no real history/collection entry it could
/// collide with.
BangumiItem _fixtureBangumiItem() {
  return BangumiItem(
    id: 900000001,
    type: 2,
    name: _targetNameRomaji,
    nameCn: _targetNameCn,
    summary: 'Integration-test fixture bangumi item for auto-selection '
        'live verification (see '
        'integration_test/auto_source_selection_test.dart).',
    airDate: '2022-04-09',
    airWeekday: 6,
    rank: 1,
    images: const {},
    tags: const [],
    alias: const [],
    ratingScore: 8.0,
    votes: 1000,
    votesCount: List<int>.filled(10, 10),
    info: '',
  );
}

/// Copies the real app's installed plugin rule files into the isolated
/// storage directory this test boots against, so the auto-selection race
/// has real, user-installed sources to probe instead of none. Falls back
/// to the bundled assets/plugins/*.json defaults (the same set
/// test/live/live_source_verification_test.dart reads) if the real app's
/// storage can't be found, e.g. on a machine that has never run Kazumi.
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
/// Mirrors the pattern in test/live/live_source_verification_test.dart,
/// extended with getTemporaryPath since this test boots the full real app
/// (lib/main.dart's main()), which touches more of path_provider than that
/// suite's narrower boot does.
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
  // test boots the FULL real app, which pulls in more plugins than the
  // narrower live suite does.
  @override
  Future<String?> getApplicationDocumentsPath() async => '$_supportPath/documents';

  @override
  Future<String?> getLibraryPath() async => '$_supportPath/library';

  @override
  Future<String?> getApplicationCachePath() async => '$_tempPath/cache';

  @override
  Future<String?> getDownloadsPath() async => '$_tempPath/downloads';
}
