// Drives the REAL Kazumi macOS app (compiled build, real WebViews, real
// network) to verify the PlayableSourceCache "warm" path -- see
// docs/ideas/source-auto-selection.md's cache section and
// lib/services/plugin/playable_source_cache.dart. Every case in
// auto_source_selection_test.dart boots against fresh, empty isolated
// storage, so PlayableSourceCache has never actually influenced a real
// race in any prior live run. This file seeds it directly (via the same
// GStorage/`setting` box wiring video_controller.dart itself uses) and
// proves the cache actually changes the race, not just the offline unit
// suite's fake read/write functions:
//
//   A1 -- a fresh cached record for the show ranks its plugin FIRST in
//         VideoPageController.probeCandidateOrder.
//   A2 -- a record older than the 7-day TTL reads back as expired through
//         the REAL storage (GStorage.getSetting/putSetting -> the `setting`
//         Hive box), and does not receive forced priority in a live race.
//   A3 -- a successful auto-selection PERSISTS a record naming the actual
//         winner (not necessarily the seeded plugin) with a fresh
//         lastGoodAt.
//
// Run with:
//   export PATH="$HOME/develop/flutter/bin:$PATH"
//   flutter test integration_test/auto_source_selection_cache_test.dart -d macos
//
// This test hits REAL third-party scraper sites through the user's real
// installed plugins (copied -- never moved -- into an isolated Hive/storage
// directory; see _seedIsolatedPluginDirectory and
// _IsolatedPathProviderPlatform below, both mirrored verbatim from
// auto_source_selection_test.dart). A dead source is NOT a test failure:
// every hard assertion below is conditioned on the relevant plugin actually
// having become a real candidate this run (network-dependent); when it
// didn't, the case prints why it could not be verified instead of failing
// or asserting vacuously. The one exception is A2's storage-level TTL
// check, which is fully deterministic and network-independent by
// construction -- it is the "not just unit tests" proof the case exists
// for.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kazumi/main.dart' as app;
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/pages/index_page.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/plugin/playable_source_cache.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Same target as auto_source_selection_test.dart -- long running, popular,
/// and (per that suite's last recorded live run) actually carried by this
/// install's real plugins.
const _targetNameCn = '间谍过家家';
const _targetNameRomaji = 'SPY×FAMILY';

/// Distinct synthetic bangumi ids per sub-case so PlayableSourceCache
/// entries (keyed by bangumi id) never collide with each other or with
/// auto_source_selection_test.dart's fixture (900000001).
const _a1BangumiId = 920000001;
const _a2BangumiId = 920000002;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'PlayableSourceCache warm path: A1 (priority) / A2 (TTL expiry) / '
    'A3 (persistence) live verification',
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

      app.main();
      await tester.pump();

      final booted = await _pumpUntil(
        tester,
        () => find.byType(IndexPage).evaluate().isNotEmpty,
        timeout: const Duration(seconds: 60),
      );
      if (!booted) {
        fail('App did not reach the tab shell (IndexPage) within 60s after '
            'boot (pluginCount=$pluginCount).');
      }
      print('[setup] App booted to the tab shell.');

      final pluginsController = inject<PluginsController>();
      print('[setup] ${pluginsController.pluginList.length} real plugin(s) '
          'loaded: ${pluginsController.pluginList.map((p) => p.name).toList()}');

      // The exact same GStorage/`setting`-box wiring video_controller.dart's
      // private _readPlayableSourceCacheJson/_writePlayableSourceCacheJson
      // use -- constructing our own instance here reaches the identical
      // underlying Hive box (same process, same GStorage statics), so
      // whatever this writes is exactly what the app's own cache will read,
      // and vice versa.
      final testCache = PlayableSourceCache(
        read: () {
          final raw = GStorage.getSetting(SettingsKeys.playableSourceCache);
          return raw.isEmpty ? null : raw;
        },
        write: (json) =>
            GStorage.putSetting(SettingsKeys.playableSourceCache, json),
      );

      // Best real candidate to seed with: the doc's own last live run
      // ("First live run (2026-08-02)") found 7sefun the most reliable
      // source for this exact show. Fall back to whichever real plugin
      // happens to be installed first if 7sefun isn't among them, so this
      // still runs meaningfully against a different real plugin set.
      final installedNames =
          pluginsController.pluginList.map((p) => p.name).toList();
      final seedPluginName = installedNames.contains('7sefun')
          ? '7sefun'
          : (installedNames.isNotEmpty ? installedNames.first : '');
      if (seedPluginName.isEmpty) {
        fail('No plugins installed at all (pluginCount=$pluginCount) -- '
            'cannot exercise any of A1/A2/A3 without at least one real '
            'plugin.');
      }
      print('[setup] Seeding cache assertions against plugin '
          '"$seedPluginName".');

      // ================================================================
      // A1 + A3: fresh cached record -> must rank first; a real win must
      // persist a fresh record naming the actual winner.
      // ================================================================
      await testCache.put(
        _a1BangumiId,
        PlayableSourceRecord(
          pluginName: seedPluginName,
          src: 'integration-test-seed-src-a1',
          roadIndex: 0,
          // Old enough (3 days) that a later fresh write is unambiguous,
          // but well inside the 7-day TTL so cache.get() still returns it.
          lastGoodAt: DateTime.now().subtract(const Duration(days: 3)),
        ),
      );
      print('[A1] Seeded a 3-day-old (still-fresh) cached record for '
          'bangumi=$_a1BangumiId -> pluginName=$seedPluginName.');

      final homeContext = tester.element(find.byType(IndexPage));
      final bangumiItemA1 = _fixtureBangumiItem(id: _a1BangumiId);
      final controllerA1 = await _enterPlayerViaFab(
        tester,
        homeContext,
        bangumiItemA1,
        label: 'A1/A3',
      );

      if (controllerA1 == null) {
        print('[A1] SKIPPED: could not reach the player (see reason above).');
      } else {
        final gotCandidates = await _waitForCandidatesOrTerminal(
          tester,
          controllerA1,
          timeout: const Duration(seconds: 60),
        );
        final orderA1 = controllerA1.probeCandidateOrder.toList();
        print('[A1] probe candidate order: $orderA1');
        if (!gotCandidates) {
          print('[A1] SKIPPED: no candidates were ever collected this run '
              '(errorMessage=${controllerA1.errorMessage}, '
              'probeExhausted=${controllerA1.probeExhausted}) -- likely the '
              'whole network is down for this run, not a feature bug.');
        } else if (!orderA1.contains(seedPluginName)) {
          print('[A1] SKIPPED: "$seedPluginName" search-matched nothing '
              'usable for this show in this run\'s live search, so it '
              'never became a real probe candidate (network/rule-parse '
              'miss, not a cache-priority bug). Real candidates this run: '
              '$orderA1');
        } else {
          expect(
            orderA1.first,
            equals(seedPluginName),
            reason: 'A1: a fresh cached record\'s plugin must be probed '
                'FIRST (candidate_ranker.dart\'s cachedTier), but the race '
                'order was $orderA1',
          );
          print('[A1] PASS: cached source "$seedPluginName" ranked first '
              'in a real race (order: $orderA1).');
        }

        // Drive to terminal for A3 regardless of whether A1 could be
        // verified above -- a real win is what A3 needs.
        final outcome = await _runToTerminal(
          tester,
          controllerA1,
          budget: const Duration(seconds: 90),
        );
        print('[A1/A3] race terminated: $outcome');

        if (outcome == _RaceOutcome.playbackStarted) {
          final persisted = testCache.get(_a1BangumiId);
          expect(
            persisted,
            isNotNull,
            reason: 'A3: a successful auto-selection must persist a '
                'PlayableSourceRecord for the show',
          );
          expect(
            persisted!.pluginName,
            equals(controllerA1.currentPlugin.name),
            reason: 'A3: the persisted record must name the ACTUAL winner '
                '(${controllerA1.currentPlugin.name}), not necessarily the '
                'seeded plugin ($seedPluginName)',
          );
          final ageMs =
              DateTime.now().difference(persisted.lastGoodAt).inMilliseconds;
          expect(
            ageMs,
            lessThan(const Duration(minutes: 2).inMilliseconds),
            reason: 'A3: lastGoodAt must be freshly written by this run '
                '(the seed was deliberately 3 days old), got '
                '${persisted.lastGoodAt} (age ${ageMs}ms)',
          );
          expect(
            ageMs,
            greaterThanOrEqualTo(0),
            reason: 'A3: lastGoodAt must not be in the future',
          );
          print('[A3] PASS: persisted pluginName=${persisted.pluginName}, '
              'lastGoodAt=${persisted.lastGoodAt} (age ${ageMs}ms), '
              'src=${persisted.src}, roadIndex=${persisted.roadIndex}.');
        } else {
          print('[A3] SKIPPED: no real win this run (outcome=$outcome) -- '
              'a losing/exhausted race intentionally does not persist '
              '(video_controller.dart only calls PlayableSourceCache.put '
              'on result != null), so there is nothing to verify. Not a '
              'test failure: dead sources are expected.');
        }

        await _returnHome(tester, controllerA1, homeContext);
      }

      // ================================================================
      // A2: expired (>7 day) record must read back as null through the
      // REAL storage, and must not force priority in a live race.
      // ================================================================
      final staleRecord = PlayableSourceRecord(
        pluginName: seedPluginName,
        src: 'integration-test-seed-src-a2',
        roadIndex: 0,
        lastGoodAt: DateTime.now().subtract(const Duration(days: 8)),
      );
      await testCache.put(_a2BangumiId, staleRecord);
      final expiredLookup = testCache.get(_a2BangumiId);
      expect(
        expiredLookup,
        isNull,
        reason: 'A2: an 8-day-old record (TTL is 7 days) must read back as '
            'expired (null) through the REAL GStorage-backed `setting` box '
            '-- PlayableSourceCache.ttl end to end, not just the fake '
            'read/write functions test/playable_source_cache_test.dart '
            'uses',
      );
      print('[A2] PASS (storage-level, deterministic): an 8-day-old record '
          'round-tripped through GStorage.getSetting/putSetting and '
          'correctly reads back as expired (null).');

      final bangumiItemA2 = _fixtureBangumiItem(id: _a2BangumiId);
      final controllerA2 = await _enterPlayerViaFab(
        tester,
        homeContext,
        bangumiItemA2,
        label: 'A2',
      );
      if (controllerA2 == null) {
        print('[A2] Live ordering check SKIPPED: could not reach the '
            'player (see reason above). The storage-level proof above is '
            'unaffected.');
      } else {
        final gotCandidates = await _waitForCandidatesOrTerminal(
          tester,
          controllerA2,
          timeout: const Duration(seconds: 60),
        );
        final orderA2 = controllerA2.probeCandidateOrder.toList();
        final expiredPluginPresent = orderA2.contains(staleRecord.pluginName);
        final independentlySearchValid =
            pluginsController.validityTracker.isSearchValid(
          staleRecord.pluginName,
        );
        print('[A2] Live race candidate order: $orderA2 (expired-cache '
            'plugin="${staleRecord.pluginName}", '
            'presentAsCandidate=$expiredPluginPresent, '
            'independentlySearchValid=$independentlySearchValid)');
        if (!gotCandidates) {
          print('[A2] Live ordering check inconclusive: no candidates '
              'collected this run (network likely down). Storage-level '
              'proof above stands regardless.');
        } else if (expiredPluginPresent &&
            !independentlySearchValid &&
            orderA2.length > 1) {
          // The only remaining way this plugin could land first is a
          // wrongly-honoured expired cache entry, since it is not
          // independently search-valid and at least one other real
          // candidate exists to be ranked ahead of it in the "rest" tier
          // ties (list order) -- so this is a decisive, non-vacuous check.
          expect(
            orderA2.first,
            isNot(equals(staleRecord.pluginName)),
            reason: 'A2: an expired cache record must not force its '
                'plugin to the front of a live race when it is not '
                'independently search-valid and other real candidates '
                'exist. Order was $orderA2',
          );
          print('[A2] PASS (live): expired-cache plugin did not receive '
              'forced priority in a real race.');
        } else {
          print('[A2] Live ordering check not conclusive this run '
              '(plugin absent as a candidate, independently search-valid '
              'anyway, or the only candidate) -- the deterministic '
              'storage-level check above is the decisive proof for this '
              'case.');
        }

        await _returnHome(tester, controllerA2, homeContext);
      }
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

enum _RaceOutcome { playbackStarted, failedGracefully, timedOut }

/// Polls [condition] by pumping [tester] every [step] until it is true or
/// [timeout] elapses. Mirrors auto_source_selection_test.dart's own helper
/// -- deliberately never pumpAndSettle (see that file's doc comment).
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

/// Navigates home -> info -> tap 开始观看 -> player, exactly like
/// auto_source_selection_test.dart's I1, and returns the page-scoped
/// VideoPageController, or null (printing why) if any step failed.
Future<VideoPageController?> _enterPlayerViaFab(
  WidgetTester tester,
  BuildContext homeContext,
  BangumiItem bangumiItem, {
  required String label,
}) async {
  homeContext.pushNamed('/info/', arguments: bangumiItem);
  final onInfoPage = await _pumpUntil(
    tester,
    () => find.text('开始观看').evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
  );
  if (!onInfoPage) {
    print('[$label] InfoPage did not render the 开始观看 FAB within 20s.');
    return null;
  }
  // Give the info page's background plugin search a head start (see
  // auto_source_selection_test.dart's I1 comment for why).
  await tester.pump(const Duration(seconds: 4));

  await tester.tap(find.text('开始观看'));
  await tester.pump();

  final onPlayer = await _pumpUntil(
    tester,
    () => find.byType(GridView).evaluate().isNotEmpty,
    timeout: const Duration(seconds: 20),
  );
  if (!onPlayer) {
    print('[$label] Did not land on the player within 20s of tapping '
        '开始观看.');
    return null;
  }
  final videoPageContext = tester.element(find.byType(GridView).first);
  return videoPageContext.read<VideoPageController>();
}

/// Waits until either the probe race has started reporting candidates, or
/// it has already terminated (win or graceful failure) without ever
/// reporting any -- i.e. the whole network was down for this run. Returns
/// whether candidates were actually collected.
Future<bool> _waitForCandidatesOrTerminal(
  WidgetTester tester,
  VideoPageController controller, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  bool terminal() =>
      controller.playingEpisode != null ||
      (controller.errorMessage != null && controller.probeExhausted);
  while (controller.probeCandidateOrder.isEmpty &&
      !terminal() &&
      DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  return controller.probeCandidateOrder.isNotEmpty;
}

/// Pumps until auto-selection reaches one of its two terminal states or
/// [budget] elapses. Never asserts on which outcome occurs -- a dead
/// source is not a test failure (see file header).
Future<_RaceOutcome> _runToTerminal(
  WidgetTester tester,
  VideoPageController controller, {
  required Duration budget,
}) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    if (controller.playingEpisode != null) {
      return _RaceOutcome.playbackStarted;
    }
    if (controller.errorMessage != null && controller.probeExhausted) {
      return _RaceOutcome.failedGracefully;
    }
    await tester.pump(const Duration(milliseconds: 300));
  }
  if (controller.playingEpisode != null) return _RaceOutcome.playbackStarted;
  if (controller.errorMessage != null && controller.probeExhausted) {
    return _RaceOutcome.failedGracefully;
  }
  return _RaceOutcome.timedOut;
}

/// Best-effort teardown between sub-cases: pops the player (and info page
/// beneath it) back to the tab shell so the previous VideoPageController is
/// disposed (cancelling its resolver pool / in-flight probe, per
/// video_controller.dart's dispose()) before the next sub-case starts a new
/// race. Never fails the test on its own -- a leftover background
/// controller is a hygiene concern, not a correctness one, and this is not
/// itself part of the feature under test.
Future<void> _returnHome(
  WidgetTester tester,
  VideoPageController controller,
  BuildContext homeContext,
) async {
  try {
    Navigator.of(homeContext).popUntil((route) => route.isFirst);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.text('开始观看').evaluate().isEmpty &&
          find.byType(GridView).evaluate().isEmpty,
      timeout: const Duration(seconds: 15),
    );
  } catch (e) {
    print('[cleanup] Best-effort return-to-home navigation failed ($e) -- '
        'continuing anyway; the next sub-case will still push its own new '
        'route.');
  }
}

/// Fully populated so InfoPage's `_needsBangumiInfoRefresh` is false and it
/// never calls out to bgm.tv. Mirrors auto_source_selection_test.dart's
/// fixture, parameterised by id so each sub-case gets its own
/// PlayableSourceCache slot.
BangumiItem _fixtureBangumiItem({required int id}) {
  return BangumiItem(
    id: id,
    type: 2,
    name: _targetNameRomaji,
    nameCn: _targetNameCn,
    summary: 'Integration-test fixture bangumi item for '
        'auto_source_selection_cache_test.dart.',
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
/// storage directory this test boots against. Verbatim from
/// auto_source_selection_test.dart -- see that file for the full rationale.
/// This only ever READS the real app's plugins.json -- never writes to it.
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
/// test run instead of the real device Application Support directory.
/// Verbatim from auto_source_selection_test.dart.
class _IsolatedPathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _IsolatedPathProviderPlatform(this._supportPath, this._tempPath);
  final String _supportPath;
  final String _tempPath;

  @override
  Future<String?> getApplicationSupportPath() async => _supportPath;

  @override
  Future<String?> getTemporaryPath() async => _tempPath;

  @override
  Future<String?> getApplicationDocumentsPath() async =>
      '$_supportPath/documents';

  @override
  Future<String?> getLibraryPath() async => '$_supportPath/library';

  @override
  Future<String?> getApplicationCachePath() async => '$_tempPath/cache';

  @override
  Future<String?> getDownloadsPath() async => '$_tempPath/downloads';
}
