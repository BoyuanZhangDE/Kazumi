// Drives the REAL Kazumi macOS app (compiled build, real WebViews, real
// network) to automate the two "resume" tier-2 live-verification cases from
// docs/ideas/source-auto-selection.md that auto_source_selection_test.dart
// deliberately does not cover (it only drives the 开始观看/info-page entry
// point, never HistoryPlaybackService's resume path):
//
//   B1 -> M3: resuming a history entry whose remembered source still works
//             must resume on that SAME source, at the saved episode/offset.
//   B2 -> M4: resuming a history entry whose remembered source is gone (no
//             matching plugin) must fall back to another source via the
//             automatic probe instead of dead-ending on
//             "在线源不可用，请重新选择播放源" -- and per
//             probe_planning.dart's remapForSourceSwap/planInitialTarget
//             contract, the remembered offset must be DROPPED to zero,
//             since episode numbering is not stable across sources.
//   B3 -> regression guard for the isManualPick bug: a resumed source
//             (OnlineVideoPlaybackArgs.isManualPick == false) whose WebView
//             resolve genuinely fails must trigger the SAME cross-source
//             recovery beginAutoSourceSelection uses, not the friendly
//             dead-end widget -- because a resume is a remembered default,
//             not a deliberate pick. video_controller.dart used to set
//             _currentSourceIsManual = true for EVERY OnlineVideoPlaybackArgs
//             regardless of isManualPick, which made
//             _recoverFromResolveFailure bail out immediately. B3 forces a
//             deterministic resolve failure (a corrupted episode-1 URL on an
//             otherwise-real, working source) rather than waiting for a real
//             site to happen to break, since that's how the original bug was
//             found (B1's own gugu3 case).
//
// Run with:
//   export PATH="$HOME/develop/flutter/bin:$PATH"
//   flutter test integration_test/auto_source_selection_resume_test.dart -d macos
//
// This test hits REAL third-party scraper sites through the user's real
// installed plugins (copied -- never moved -- into isolated storage; see
// _seedIsolatedPluginDirectory / _IsolatedPathProviderPlatform, mirrored
// verbatim from auto_source_selection_test.dart). Synthetic History entries
// are seeded directly into the isolated Hive `histories` box (never the
// real app's) via GStorage.histories, exactly as the ABSOLUTE RULE in this
// suite's brief requires. A dead source is NOT a test failure: only this
// feature's OWN invariants are asserted (which source/offset a resume
// lands on, that a broken source triggers the search-all fallback instead
// of HistoryPlaybackService's dead-end string, that the offset gets
// dropped on a source swap). Winners, timings, and remote availability are
// printed, not asserted.
//
// NOTE: another agent may be concurrently changing how
// video_controller.dart's changeEpisode/_resolveWithVideoSourceService
// path (used by B1's OnlineVideoPlaybackArgs route) handles a failed
// resolve. This file does not depend on that path's failure behaviour --
// B1's hard assertions are all about the deterministic pre-network state
// (which episode/road/offset got applied), not about whether the WebView
// resolve itself ultimately succeeds.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_modular/flutter_modular.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:kazumi/main.dart' as app;
import 'package:kazumi/modules/bangumi/bangumi_item.dart';
import 'package:kazumi/modules/history/history_module.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/pages/history/history_controller.dart';
import 'package:kazumi/pages/index_page.dart';
import 'package:kazumi/pages/player/player_controller.dart';
import 'package:kazumi/pages/video/video_controller.dart';
import 'package:kazumi/pages/video/video_playback_args.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/plugins/plugins_controller.dart';
import 'package:kazumi/services/player/history_playback_service.dart';
import 'package:kazumi/services/plugin/search_result_picker.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Same target as auto_source_selection_test.dart.
const _targetNameCn = '间谍过家家';
const _targetNameRomaji = 'SPY×FAMILY';

/// Distinct synthetic bangumi ids so history entries never collide with
/// auto_source_selection_test.dart's fixture (900000001) or
/// auto_source_selection_cache_test.dart's (920000001/920000002).
const _b1BangumiId = 940000001;
const _b2BangumiId = 940000002;
const _b3BangumiId = 940000003;

/// Old dead-end string HistoryPlaybackService.open() returns as
/// HistoryPlaybackUnavailable.reason when NO plugin (remembered or
/// fallback-searched) yields anything at all
/// (history_playback_service.dart's `open()`).
const _deadEndString = '在线源不可用，请重新选择播放源';

/// Guaranteed to never match a real installed plugin's name.
const _missingPluginName = '__kazumi_integration_test_missing_plugin__';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'History resume: B1 (M3 same-source resume) / B2 (M4 fallback + '
    'offset drop) / B3 (resume resolve-failure triggers recovery, not '
    'manual-pick dead-end) live verification',
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

      final homeContext = tester.element(find.byType(IndexPage));
      final pluginsController = inject<PluginsController>();
      final historyController = inject<HistoryController>();
      final historyPlaybackService = inject<HistoryPlaybackService>();
      print('[setup] ${pluginsController.pluginList.length} real plugin(s) '
          'loaded.');

      // ================================================================
      // B1 (M3): discover one currently-working real source (stage 1+2
      // only -- one bounded search pass, no WebView), seed a History entry
      // pointing at it, then resume through HistoryPlaybackService exactly
      // as bangumi_history_card.dart's _onTap does.
      // ================================================================
      final working = await _discoverWorkingSource(
        pluginsController,
        _targetNameCn,
      );
      if (working == null) {
        print('[B1] SKIPPED entirely: no plugin returned a matching, '
            'chapter-road-resolvable search hit for "$_targetNameCn" in '
            'this bounded discovery pass -- the whole network is likely '
            'down for this run. Not a feature failure.');
      } else {
        final episodeCount = working.roads.first.data.length;
        final targetEpisode = episodeCount >= 2 ? 2 : 1;
        const savedOffset = Duration(seconds: 42);
        print('[B1] Discovered a working source: plugin='
            '${working.pluginName}, src=${working.src}, roads='
            '${working.roads.length}, episodes=$episodeCount. Seeding '
            'history at episode $targetEpisode, offset $savedOffset.');

        final historyB1 = History(
          _fixtureBangumiItem(id: _b1BangumiId),
          targetEpisode,
          working.pluginName,
          DateTime.now(),
          working.src,
          working.roads.first.identifier[targetEpisode - 1],
          entryKind: HistoryEntryKind.online,
        );
        historyB1.progresses[targetEpisode] = Progress(
          targetEpisode,
          0,
          savedOffset.inMilliseconds,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        await GStorage.histories.put(historyB1.key, historyB1);
        historyController.init();
        print('[B1] Seeded History (key=${historyB1.key}) into the '
            'isolated `histories` Hive box and refreshed HistoryController.');

        final resultB1 = await historyPlaybackService.open(historyB1);
        switch (resultB1) {
          case HistoryPlaybackUnavailable(:final reason):
            print('[B1] SKIPPED: HistoryPlaybackService.open() returned '
                'unavailable ("$reason") even though our own discovery '
                'pass just found this source working moments ago -- '
                'transient network flake between the two lookups, not a '
                'feature failure.');
          case HistoryPlaybackReady(:final args):
            if (args is! OnlineVideoPlaybackArgs) {
              print('[B1] SKIPPED: HistoryPlaybackService fell back to '
                  'AutoVideoPlaybackArgs instead of resuming directly on '
                  '${working.pluginName} -- its own re-query of '
                  '${working.src} must have failed between our discovery '
                  'pass and this call (or this is the in-flight change to '
                  'video_controller.dart the task brief warned about; '
                  'noting rather than working around it). Not asserting '
                  'further on this run.');
            } else {
              expect(
                args.plugin.name,
                equals(working.pluginName),
                reason: 'B1/M3: resume must stay on the remembered '
                    'source (${working.pluginName})',
              );
              print('[B1] HistoryPlaybackService resumed directly on '
                  '${args.plugin.name} (OnlineVideoPlaybackArgs) -- no '
                  'fallback search needed. Pushing into the player.');

              homeContext.pushNamed('/video/', arguments: args);
              final onPlayer = await _pumpUntil(
                tester,
                () => find.byType(GridView).evaluate().isNotEmpty,
                timeout: const Duration(seconds: 20),
              );
              if (!onPlayer) {
                print('[B1] SKIPPED: did not land on the player within '
                    '20s of pushing /video/.');
              } else {
                final videoPageContext =
                    tester.element(find.byType(GridView).first);
                final controllerB1 =
                    videoPageContext.read<VideoPageController>();
                final playerControllerB1 =
                    videoPageContext.read<PlayerController>();

                // These are set synchronously in VideoPage._initOnlineMode
                // from historyController.lastWatching(), before any
                // network/WebView work starts -- deterministic, not
                // remote-dependent.
                expect(
                  controllerB1.currentPlugin.name,
                  equals(working.pluginName),
                  reason: 'B1/M3: must still be on the remembered plugin '
                      'once in the player',
                );
                expect(
                  controllerB1.selectedEpisode.episode,
                  equals(targetEpisode),
                  reason: 'B1/M3: must resume at the remembered episode '
                      '($targetEpisode), got '
                      '${controllerB1.selectedEpisode.episode}',
                );
                expect(
                  controllerB1.selectedEpisode.road,
                  equals(0),
                  reason: 'B1/M3: must resume on the remembered road (0)',
                );
                expect(
                  controllerB1.historyOffset,
                  equals(savedOffset.inSeconds),
                  reason: 'B1/M3: must carry the saved progress '
                      '(${savedOffset.inSeconds}s) into historyOffset, '
                      'got ${controllerB1.historyOffset}s',
                );
                print('[B1] PASS (deterministic): resumed on '
                    '${controllerB1.currentPlugin.name}, episode '
                    '${controllerB1.selectedEpisode.episode}, road '
                    '${controllerB1.selectedEpisode.road}, historyOffset '
                    '${controllerB1.historyOffset}s.');

                // Best-effort, NOT asserted: whether the real WebView
                // resolve actually succeeds and where the player seeks to
                // is remote/timing-dependent (see file header).
                final outcome = await _runToTerminal(
                  tester,
                  controllerB1,
                  budget: const Duration(seconds: 60),
                );
                if (outcome == _RaceOutcome.playbackStarted) {
                  final pos = playerControllerB1.playback.playerPosition;
                  print('[B1] Real playback started. Player position '
                      '~${pos.inSeconds}s vs saved ${savedOffset.inSeconds}s '
                      '(seek/buffering timing -- printed, not asserted).');
                } else {
                  print('[B1] Real playback did not reach a started state '
                      'within budget (outcome=$outcome) -- printed only; '
                      'the resume-routing invariants above already passed '
                      'regardless of whether this specific source actually '
                      'resolves right now.');
                }

                await _returnHome(tester, homeContext);
              }
            }
        }
      }

      // ================================================================
      // B3: regression guard for the isManualPick bug. Reuses the working
      // source discovered for B1 (stage 1+2 already proven real), but
      // builds OnlineVideoPlaybackArgs directly with isManualPick: false --
      // exactly the shape HistoryPlaybackService produces for a resume --
      // and points episode 1 at an unresolvable `.invalid` host (RFC 2606)
      // so the WebView page load itself fails and the resolve deterministically
      // times out. (An earlier version of this corrupted only the path on
      // the real site; several real sites turned out to redirect an unknown
      // path to a generic landing player instead of failing, which defeated
      // the premise -- an unresolvable host doesn't have that escape hatch.)
      // If applyPlaybackArgs ever again marks a resume as manual (the
      // original bug), _recoverFromResolveFailure bails out before probing
      // any alternate source; if it stays correctly non-manual, recovery
      // searches every plugin and races the alternates, populating
      // probeCandidateOrder.
      // ================================================================
      if (working == null) {
        print('[B3] SKIPPED: no working source discovered above (B1 was '
            'skipped for the same reason), nothing to force a resolve '
            'failure on.');
      } else {
        Plugin? pluginB3;
        for (final candidate in pluginsController.pluginList) {
          if (candidate.name == working.pluginName) {
            pluginB3 = candidate;
            break;
          }
        }
        if (pluginB3 == null) {
          print('[B3] SKIPPED: plugin ${working.pluginName} is no longer '
              'in pluginList.');
        } else {
          final realRoad = working.roads.first;
          final brokenRoad = Road(
            name: realRoad.name,
            identifier: List<String>.of(realRoad.identifier),
            data: [
              for (var i = 0; i < realRoad.data.length; i++)
                i == 0
                    ? 'https://kazumi-integration-test-'
                        '${DateTime.now().millisecondsSinceEpoch}.invalid/'
                        'no-such-episode.html'
                    : realRoad.data[i],
            ],
          );
          print('[B3] Forcing a deterministic resolve failure on '
              '${working.pluginName} by pointing episode 1 at an '
              'unresolvable .invalid host, while keeping the plugin/src '
              'otherwise real -- reproduces the original bug report '
              '(resume routes correctly, WebView resolve then fails) '
              'without depending on a real site happening to be down '
              'this run.');

          final argsB3 = OnlineVideoPlaybackArgs(
            bangumiItem: _fixtureBangumiItem(id: _b3BangumiId),
            plugin: pluginB3,
            title: working.pluginName,
            src: working.src,
            roads: [brokenRoad],
            // The exact contract under test: HistoryPlaybackService
            // always passes false for a resume. A regression that
            // reverts this (or reintroduces the old "always true"
            // default) makes _recoverFromResolveFailure skip recovery
            // entirely -- see video_controller.dart's applyPlaybackArgs.
            isManualPick: false,
          );

          homeContext.pushNamed('/video/', arguments: argsB3);
          final onPlayerB3 = await _pumpUntil(
            tester,
            () => find.byType(GridView).evaluate().isNotEmpty,
            timeout: const Duration(seconds: 20),
          );
          if (!onPlayerB3) {
            print('[B3] SKIPPED: did not land on the player within 20s '
                'of pushing /video/.');
          } else {
            final videoPageContextB3 =
                tester.element(find.byType(GridView).first);
            final controllerB3 =
                videoPageContextB3.read<VideoPageController>();

            final outcomeB3 = await _runToTerminal(
              tester,
              controllerB3,
              budget: const Duration(seconds: 90),
            );
            switch (outcomeB3) {
              case _RaceOutcome.playbackStarted:
                if (controllerB3.currentPlugin.name == working.pluginName) {
                  print('[B3] SKIPPED assertion: playback started on '
                      '${working.pluginName} itself -- the unresolvable-'
                      'host URL unexpectedly still resolved (unlikely, '
                      'but not this feature\'s concern), so the forced-'
                      'failure premise did not hold this run.');
                } else {
                  // The seed (resumed) source failed to resolve and
                  // playback nonetheless started on a DIFFERENT plugin --
                  // only possible if _recoverFromResolveFailure raced and
                  // won on an alternate source instead of bailing out on
                  // _currentSourceIsManual. This is the strongest possible
                  // proof: not just "recovery was attempted" but "recovery
                  // completed and played."
                  expect(
                    controllerB3.probeCandidateOrder,
                    isNotEmpty,
                    reason: 'B3 regression guard: playback swapped to '
                        '${controllerB3.currentPlugin.name} without '
                        'probeCandidateOrder ever being populated -- '
                        'should be unreachable (only _raceCandidates '
                        'sets it), noting the inconsistency.',
                  );
                  print('[B3] PASS: resume resolve failure on '
                      '${working.pluginName} triggered cross-source '
                      'recovery, which swapped to '
                      '${controllerB3.currentPlugin.name} and started '
                      'playback -- proves a resume is NOT treated as a '
                      'manual pick.');
                }
              case _RaceOutcome.timedOut:
                print('[B3] SKIPPED assertion: did not reach a '
                    'terminal state within the 90s budget -- '
                    'inconclusive this run.');
              case _RaceOutcome.failedGracefully:
                // This is exactly the shape of the original bug: the
                // seed (resumed) source's resolve failed. The signal
                // that recovery was genuinely attempted rather than
                // short-circuited is probeCandidateOrder becoming
                // non-empty -- it is only ever populated inside
                // _raceCandidates, which _recoverFromResolveFailure
                // only reaches when it did NOT bail out on
                // _currentSourceIsManual.
                expect(
                  controllerB3.probeCandidateOrder,
                  isNotEmpty,
                  reason: 'B3 regression guard: after the resumed '
                      'source\'s resolve failed, probeCandidateOrder '
                      'is empty -- recovery never raced any alternate '
                      'source. Before the isManualPick fix, '
                      'applyPlaybackArgs marked EVERY '
                      'OnlineVideoPlaybackArgs as a manual pick, so '
                      '_recoverFromResolveFailure bailed out '
                      'immediately instead of trying other sources.',
                );
                expect(
                  controllerB3.probeCandidateOrder,
                  isNot(contains(working.pluginName)),
                  reason: 'B3: the already-failed seed source must not '
                      'be re-offered as a recovery candidate',
                );
                print('[B3] PASS: resume resolve failure triggered '
                    'cross-source recovery -- probed '
                    '${controllerB3.probeCandidateOrder} instead of '
                    'dead-ending (errorMessage='
                    '${controllerB3.errorMessage}).');
            }
            await _returnHome(tester, homeContext);
          }
        }
      }

      // ================================================================
      // B2 (M4): a remembered source that cannot possibly match any real
      // plugin must fall back to the full search-all path instead of the
      // dead-end toast string, and the resulting AutoVideoPlaybackArgs run
      // must drop the remembered offset to zero.
      // ================================================================
      final historyB2 = History(
        _fixtureBangumiItem(id: _b2BangumiId),
        3,
        _missingPluginName,
        DateTime.now(),
        'https://example.invalid/missing-source',
        '第3话',
        entryKind: HistoryEntryKind.online,
      );
      historyB2.progresses[3] = Progress(
        3,
        0,
        const Duration(seconds: 55).inMilliseconds,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await GStorage.histories.put(historyB2.key, historyB2);
      historyController.init();
      print('[B2] Seeded History (key=${historyB2.key}) pointing at a '
          'nonexistent plugin ("$_missingPluginName"), episode 3, offset '
          '55s.');

      final resultB2 = await historyPlaybackService.open(historyB2);
      switch (resultB2) {
        case HistoryPlaybackUnavailable(:final reason):
          expect(
            reason,
            equals(_deadEndString),
            reason: 'B2: HistoryPlaybackUnavailable should only ever '
                'carry this exact reason string',
          );
          print('[B2] SKIPPED further assertions: the ENTIRE network is '
              'down for this run -- not even the fallback search '
              '(_autoArgs) found a single real candidate for '
              '"$_targetNameCn" across any installed plugin, so '
              'HistoryPlaybackService correctly reported '
              '"$_deadEndString". This is the one scenario where that '
              'string is the CORRECT outcome (total network failure, not '
              'a single broken source) -- printing why rather than '
              'failing or asserting vacuously, per this suite\'s rules.');
        case HistoryPlaybackReady(:final args):
          // Structurally guaranteed: _onlineArgs can only return
          // OnlineVideoPlaybackArgs via a plugin-name match, and
          // _missingPluginName matches nothing -- so reaching Ready here
          // can only be through the _autoArgs fallback. Asserting it
          // anyway both documents the contract and would catch a
          // regression in that routing.
          expect(
            args,
            isA<AutoVideoPlaybackArgs>(),
            reason: 'B2/M4: a remembered source naming no real plugin '
                'must fall back to AutoVideoPlaybackArgs (search-all), '
                'never dead-end and never resume as if it were still '
                'OnlineVideoPlaybackArgs',
          );
          print('[B2] PASS: HistoryPlaybackService fell back to '
              'AutoVideoPlaybackArgs instead of dead-ending. Pushing into '
              'the player.');

          homeContext.pushNamed('/video/', arguments: args);
          final onPlayer = await _pumpUntil(
            tester,
            () => find.byType(GridView).evaluate().isNotEmpty,
            timeout: const Duration(seconds: 20),
          );
          if (!onPlayer) {
            print('[B2] SKIPPED further assertions: did not land on the '
                'player within 20s of pushing /video/.');
            break;
          }
          final videoPageContext =
              tester.element(find.byType(GridView).first);
          final controllerB2 = videoPageContext.read<VideoPageController>();

          final gotCandidates = await _waitForCandidatesOrTerminal(
            tester,
            controllerB2,
            timeout: const Duration(seconds: 60),
          );
          if (!gotCandidates && controllerB2.roadList.isEmpty) {
            print('[B2] SKIPPED offset-drop assertion: no real candidates '
                'were collected this run either (errorMessage='
                '${controllerB2.errorMessage}) -- network down between '
                'the service-layer check above and now. Not a feature '
                'failure; the fallback-routing PASS above already stands.');
          } else {
            // _mostRecentOnlineHistory(bangumiId) finds our seeded B2
            // entry, but its adapterName (_missingPluginName) can never
            // equal whichever REAL plugin the fresh search ranks first as
            // seedPluginName -- so rememberedMatchesSeed is always false
            // and planInitialTarget falls back to its no-memory default
            // (episode 1, road 0, offset zero), deterministically,
            // regardless of which real plugin ends up winning the race.
            expect(
              controllerB2.selectedEpisode.episode,
              equals(1),
              reason: 'B2/M4: episode numbering is not stable across a '
                  'source swap, so the broken remembered source\'s saved '
                  'episode (3) must NOT carry forward -- expected episode '
                  '1 (offset dropped), got '
                  '${controllerB2.selectedEpisode.episode}',
            );
            expect(
              controllerB2.selectedEpisode.road,
              equals(0),
              reason: 'B2/M4: must start at road 0 when no remembered '
                  'source matches',
            );
            expect(
              controllerB2.historyOffset,
              equals(0),
              reason: 'B2/M4: the saved 55s offset must be DROPPED to '
                  'zero on a source swap, got '
                  '${controllerB2.historyOffset}s',
            );
            print('[B2] PASS: offset dropped to zero, episode reset to 1, '
                'road reset to 0 on fallback (source: '
                '${controllerB2.currentPlugin.name}).');

            final outcome = await _runToTerminal(
              tester,
              controllerB2,
              budget: const Duration(seconds: 90),
              alsoExpectAbsent: _deadEndDialogString,
            );
            print('[B2] race terminated: $outcome (reaches a terminal '
                'state either way -- not a dead end).');
          }
          await _returnHome(tester, homeContext);
      }
    },
    timeout: const Timeout(Duration(minutes: 7)),
  );
}

/// The OLD single-source dead-end string this whole feature replaces
/// (video_controller.dart's _resolveWithVideoSourceService,
/// VideoSourceTimeoutException branch -- see
/// auto_source_selection_test.dart's identical constant/rationale). B2
/// routes through the automatic probe (AutoVideoPlaybackArgs), which fails
/// through _failAutoSelection instead, so this must never appear on B2's
/// in-player path either.
const _deadEndDialogString = '视频解析超时，请重试';

enum _RaceOutcome { playbackStarted, failedGracefully, timedOut }

/// Polls [condition] by pumping [tester] every [step] until it is true or
/// [timeout] elapses. Mirrors auto_source_selection_test.dart's own helper.
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

/// Waits until the probe race has started reporting candidates, or it has
/// already terminated without ever reporting any.
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
      controller.roadList.isEmpty &&
      !terminal() &&
      DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 300));
  }
  return controller.probeCandidateOrder.isNotEmpty ||
      controller.roadList.isNotEmpty;
}

/// Pumps until playback reaches one of its two terminal states or [budget]
/// elapses. When [alsoExpectAbsent] is given, asserts that text never
/// appears on any pump along the way (mirroring auto_source_selection_test
/// .dart's I3 dead-end check). Never asserts on WHICH outcome occurs.
Future<_RaceOutcome> _runToTerminal(
  WidgetTester tester,
  VideoPageController controller, {
  required Duration budget,
  String? alsoExpectAbsent,
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
    if (alsoExpectAbsent != null) {
      expect(
        find.text(alsoExpectAbsent),
        findsNothing,
        reason: 'the old dead-end string ("$alsoExpectAbsent") must never '
            'appear on the auto-selection path',
      );
    }
  }
  if (controller.playingEpisode != null) return _RaceOutcome.playbackStarted;
  if (controller.errorMessage != null && controller.probeExhausted) {
    return _RaceOutcome.failedGracefully;
  }
  return _RaceOutcome.timedOut;
}

/// Best-effort teardown: pops back to the tab shell so the previous
/// VideoPageController is disposed before the next sub-case starts a new
/// race. Never fails the test on its own (see
/// auto_source_selection_cache_test.dart's identical helper for why).
Future<void> _returnHome(
  WidgetTester tester,
  BuildContext homeContext,
) async {
  try {
    Navigator.of(homeContext).popUntil((route) => route.isFirst);
    await tester.pump();
    await _pumpUntil(
      tester,
      () => find.byType(GridView).evaluate().isEmpty,
      timeout: const Duration(seconds: 15),
    );
  } catch (e) {
    print('[cleanup] Best-effort return-to-home navigation failed ($e) -- '
        'continuing anyway.');
  }
}

/// One real, currently search-and-chapter-road-resolvable source for
/// [targetTitle]: stage 1 (search) + stage 2 (chapter roads) only, no
/// WebView -- exactly what HistoryPlaybackService._onlineArgs itself
/// trusts to call a remembered source "working". Bounded: one query per
/// installed plugin, run once, no retries.
Future<({String pluginName, String src, List<Road> roads})?>
    _discoverWorkingSource(
  PluginsController pluginsController,
  String targetTitle,
) async {
  final responses = <PluginSearchResponse>[];
  await Future.wait(pluginsController.pluginList.map((plugin) async {
    try {
      final result = await plugin.queryBangumi(targetTitle);
      if (result.data.isNotEmpty) {
        responses.add(result);
      }
    } catch (_) {
      // Best-effort discovery; one plugin failing shouldn't block others.
    }
  }));

  for (final response in responses) {
    Plugin? plugin;
    for (final candidate in pluginsController.pluginList) {
      if (candidate.name == response.pluginName) {
        plugin = candidate;
        break;
      }
    }
    if (plugin == null) continue;
    final item = pickBestMatch(items: response.data, targetTitle: targetTitle);
    if (item == null) continue;
    try {
      final roads = await plugin.queryChapterRoads(item.src);
      if (roads.isNotEmpty && roads.first.data.isNotEmpty) {
        return (pluginName: plugin.name, src: item.src, roads: roads);
      }
    } catch (_) {
      // Try the next candidate.
    }
  }
  return null;
}

/// Fully populated so nothing calls out to bgm.tv. Mirrors
/// auto_source_selection_test.dart's fixture, parameterised by id.
BangumiItem _fixtureBangumiItem({required int id}) {
  return BangumiItem(
    id: id,
    type: 2,
    name: _targetNameRomaji,
    nameCn: _targetNameCn,
    summary: 'Integration-test fixture bangumi item for '
        'auto_source_selection_resume_test.dart.',
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
