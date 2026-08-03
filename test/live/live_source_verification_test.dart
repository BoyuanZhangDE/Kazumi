// Live, real-network verification for the automatic playable-source
// selection feature (see docs/ideas/source-auto-selection.md, "Live
// Verification", cases L1-L7).
//
// These tests hit real third-party scraper sites. They are opt-in only:
//
//   flutter test                          # default: skipped, zero network
//   flutter test --tags live --run-skipped  # opt in, runs L1-L7
//
// (See dart_test.yaml at the repo root for why `--run-skipped` -- not just
// `--tags live` -- is the actual opt-in command: Dart's tag filters AND
// with the command line rather than override it, so a plain exclude in the
// config file would make this suite permanently unreachable from the CLI.)
//
// This file is DIAGNOSTIC, not a correctness gate: a dead third-party site
// is not a bug in our code. Only OUR invariants are asserted (typed
// exceptions instead of hangs, pickBestMatch/M3u8Validator contracts,
// well-formed URLs); everything about remote availability is printed, not
// asserted. Every network call carries its own timeout so one hung site
// cannot stall the run.
//
// Plugin *rule definitions* are read straight off disk with dart:io (see
// _loadBundledPlugins below) -- no app/Hive/Modular boot needed for that.
// Calling the real Plugin.queryBangumi/queryChapterRoads (L2/L4) is a
// different story: they go through the app's DioFactory, which reads proxy
// settings via GStorage.getSetting(), which is backed by a Hive box that
// only exists once GStorage.init() has run. There is no way to exercise the
// *real* search/chapter code paths without it. setUpAll below boots GStorage
// against an isolated temp directory (via a fake PathProviderPlatform, not
// the device's real one) purely so this opt-in suite can make real calls;
// it never touches the app's actual storage and never runs as part of a
// plain `flutter test` (see dart_test.yaml).
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/modules/roads/road_module.dart';
import 'package:kazumi/modules/search/plugin_search_module.dart';
import 'package:kazumi/plugins/plugins.dart';
import 'package:kazumi/services/plugin/m3u8_validator.dart';
import 'package:kazumi/services/plugin/search_result_picker.dart';
import 'package:kazumi/services/plugin/source_probe.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:kazumi/utils/string_similarity.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Show used for the real search in L2. Long-running and popular enough to
/// plausibly be carried by any of the bundled sources.
const _targetTitle = '间谍过家家';

/// A stable, well-known public HLS sample used for L5 (validator accepts
/// real media).
const _knownGoodM3u8 =
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // TestWidgetsFlutterBinding installs an HttpOverrides that fakes every
  // HttpClient to return 400 without touching the network -- a safety net
  // for widget tests that never intend to make real requests. This suite's
  // entire point is real requests, so it must be turned back off.
  HttpOverrides.global = null;

  late Directory tempStorageDir;

  setUpAll(() async {
    tempStorageDir =
        await Directory.systemTemp.createTemp('kazumi_live_test_storage_');
    PathProviderPlatform.instance = _FakePathProviderPlatform(tempStorageDir.path);
    // Isolated Hive instance for this suite only -- see the file header.
    // Mirrors lib/main.dart's bootstrap (Hive.initFlutter + GStorage.init),
    // using the plain (non-Flutter) Hive.init since path resolution is
    // already handled by the fake PathProviderPlatform above.
    Hive.init('${tempStorageDir.path}/hive');
    await GStorage.init();
  });

  tearDownAll(() async {
    if (await tempStorageDir.exists()) {
      await tempStorageDir.delete(recursive: true);
    }
  });

  test(
    'L1-L7: live source verification (diagnostic, opt-in, hits real hosts)',
    () async {
      final plugins = _loadBundledPlugins();
      expect(
        plugins,
        isNotEmpty,
        reason: 'expected to load the bundled *.json rule files from '
            'assets/plugins/ directly off disk',
      );

      await _runL1(plugins);
      final l2 = await _runL2(plugins);
      final l3 = _runL3(l2);
      final l4 = await _runL4(plugins, l3);
      await _runL5();
      await _runL6();
      _runL7(l4);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

/// Points GStorage at an isolated temp directory instead of the real device
/// application-support directory, so this opt-in live suite never touches
/// actual user data.
class _FakePathProviderPlatform extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProviderPlatform(this._path);
  final String _path;

  @override
  Future<String?> getApplicationSupportPath() async => _path;
}

// ---------------------------------------------------------------------------
// Plugin loading -- reads the bundled rule files straight off disk with
// dart:io, mirroring the task's instruction not to boot the app/Hive/Modular
// just to get at three JSON files.
// ---------------------------------------------------------------------------

List<Plugin> _loadBundledPlugins() {
  final dir = Directory('assets/plugins');
  final plugins = <Plugin>[];
  for (final entity in dir.listSync()) {
    if (entity is! File || !entity.path.endsWith('.json')) continue;
    final json = jsonDecode(entity.readAsStringSync()) as Map<String, dynamic>;
    plugins.add(Plugin.fromJson(json));
  }
  // Stable order so the printed report reads the same way every run.
  plugins.sort((a, b) => a.name.compareTo(b.name));
  return plugins;
}

// ---------------------------------------------------------------------------
// Real HTTP GET, wired into M3u8Validator for L5/L6 and used directly for
// L1's reachability probe.
//
// This intentionally does NOT call the app's own httpProbeGet
// (lib/services/plugin/http_probe_client.dart): that function goes through
// DioFactory.downloadDio -> NetworkConfig.fromSettings() -> GStorage
// .getSetting(), which reads a Hive box that only exists after
// GStorage.init() runs. Standing up Hive (and the path_provider platform
// channel it needs for a directory) just to perform a GET would mean
// booting real app storage from a unit test -- exactly what this harness is
// asked to avoid. This helper reproduces httpProbeGet's real request
// semantics (plain Dio GET, validateStatus accepts everything so gate B can
// inspect the actual status code, generous timeouts) without that
// dependency. It is a real network call over a real Dio client, so
// M3u8Validator is exercised with an authentic HTTP round trip either way.
// ---------------------------------------------------------------------------

final Dio _liveDio = Dio(
  BaseOptions(
    connectTimeout: const Duration(seconds: 10),
    receiveTimeout: const Duration(seconds: 15),
    sendTimeout: const Duration(seconds: 10),
    validateStatus: (_) => true,
  ),
);

Future<HttpProbeResponse> _liveHttpGet(
  String url,
  Map<String, String> headers,
) async {
  final response = await _liveDio.get<String>(
    url,
    options: Options(
      headers: {'user-agent': 'Mozilla/5.0 (KazumiLiveVerification)', ...headers},
      responseType: ResponseType.plain,
    ),
  );
  return HttpProbeResponse(
    statusCode: response.statusCode ?? 0,
    body: response.data ?? '',
  );
}

// ---------------------------------------------------------------------------
// L1 -- reach every bundled plugin's baseUrl.
// ---------------------------------------------------------------------------

Future<void> _runL1(List<Plugin> plugins) async {
  print('\n=== L1: reachability of each plugin baseUrl ===');
  for (final plugin in plugins) {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await _liveHttpGet(plugin.baseUrl, {})
          .timeout(const Duration(seconds: 20));
      stopwatch.stop();
      print('  ${_pad(plugin.name)} ${plugin.baseUrl} '
          '-> HTTP ${response.statusCode} (${stopwatch.elapsedMilliseconds}ms)');
    } catch (e) {
      stopwatch.stop();
      print('  ${_pad(plugin.name)} ${plugin.baseUrl} '
          '-> ${e.runtimeType}: $e (${stopwatch.elapsedMilliseconds}ms)');
    }
  }
}

// ---------------------------------------------------------------------------
// L2 -- real search across all plugins.
// ---------------------------------------------------------------------------

Future<Map<String, PluginSearchResponse>> _runL2(List<Plugin> plugins) async {
  print('\n=== L2: real search for "$_targetTitle" across all plugins ===');
  final results = <String, PluginSearchResponse>{};
  for (final plugin in plugins) {
    final stopwatch = Stopwatch()..start();
    try {
      final response = await plugin
          .queryBangumi(_targetTitle, shouldRethrow: true)
          .timeout(const Duration(seconds: 30));
      stopwatch.stop();
      print('  ${_pad(plugin.name)} -> ${response.data.length} result(s) '
          '(${stopwatch.elapsedMilliseconds}ms)');
      // Our invariant, not a remote-availability claim: a returned response
      // is always tagged with the plugin that produced it.
      expect(
        response.pluginName,
        plugin.name,
        reason: 'queryBangumi must tag its response with its own plugin name',
      );
      if (response.data.isNotEmpty) {
        results[plugin.name] = response;
      }
    } catch (e) {
      stopwatch.stop();
      print('  ${_pad(plugin.name)} -> ${e.runtimeType}: $e '
          '(${stopwatch.elapsedMilliseconds}ms)');
    }
  }
  return results;
}

// ---------------------------------------------------------------------------
// L3 -- pickBestMatch over whatever L2 actually returned.
// ---------------------------------------------------------------------------

Map<String, SearchItem> _runL3(Map<String, PluginSearchResponse> l2Results) {
  print('\n=== L3: pickBestMatch over real search results ===');
  if (l2Results.isEmpty) {
    print('  SKIPPED: L2 produced no search results from any plugin.');
    return const {};
  }

  final winners = <String, SearchItem>{};
  for (final entry in l2Results.entries) {
    print('  [${entry.key}] target="$_targetTitle"');
    for (final item in entry.value.data) {
      final score = calculateSimilarity(item.name, _targetTitle);
      print('    score=${score.toStringAsFixed(3)}  "${item.name}"  (src=${item.src})');
    }
    final winner = pickBestMatch(items: entry.value.data, targetTitle: _targetTitle);
    // Our invariant: pickBestMatch only returns null for an empty item list,
    // and L2 only stores non-empty responses above.
    expect(
      winner,
      isNotNull,
      reason: 'pickBestMatch must not return null for a non-empty item list',
    );
    print('    WINNER: "${winner!.name}"');
    winners[entry.key] = winner;
  }
  return winners;
}

// ---------------------------------------------------------------------------
// L4 -- queryChapterRoads on the winning src of whichever plugin worked.
// ---------------------------------------------------------------------------

class _L4Result {
  const _L4Result({required this.plugin, required this.item, required this.roads});
  final Plugin plugin;
  final SearchItem item;
  final List<Road> roads;
}

Future<_L4Result?> _runL4(
  List<Plugin> plugins,
  Map<String, SearchItem> l3Winners,
) async {
  print('\n=== L4: queryChapterRoads on the winning src ===');
  if (l3Winners.isEmpty) {
    print('  SKIPPED: L3 produced no winner (upstream L2 failure).');
    return null;
  }

  for (final entry in l3Winners.entries) {
    final plugin = plugins.firstWhere((p) => p.name == entry.key);
    final stopwatch = Stopwatch()..start();
    try {
      final roads = await plugin
          .queryChapterRoads(entry.value.src)
          .timeout(const Duration(seconds: 30));
      stopwatch.stop();
      print('  [${plugin.name}] "${entry.value.name}" -> ${roads.length} road(s) '
          '(${stopwatch.elapsedMilliseconds}ms)');
      for (final road in roads) {
        print('    road "${road.name}": ${road.data.length} episode(s)');
      }
      if (roads.isNotEmpty && roads.any((road) => road.data.isNotEmpty)) {
        return _L4Result(plugin: plugin, item: entry.value, roads: roads);
      }
    } catch (e) {
      stopwatch.stop();
      print('  [${plugin.name}] -> ${e.runtimeType}: $e (${stopwatch.elapsedMilliseconds}ms)');
    }
  }
  print('  No plugin returned usable roads/episodes; L7 will be skipped.');
  return null;
}

// ---------------------------------------------------------------------------
// L5 -- validator against a known-good public HLS playlist.
// ---------------------------------------------------------------------------

Future<void> _runL5() async {
  print('\n=== L5: M3u8Validator against a known-good public HLS playlist ===');
  final validator = M3u8Validator(get: _liveHttpGet);
  final result = await validator
      .validate(_knownGoodM3u8, {})
      .timeout(const Duration(seconds: 30));
  print('  $_knownGoodM3u8 -> $result');
  expect(
    result,
    isTrue,
    reason: "Apple's public HLS sample is a stable, well-known asset and is "
        'expected to validate true',
  );
}

// ---------------------------------------------------------------------------
// L6 -- validator against real failure modes: must return false, never
// throw.
// ---------------------------------------------------------------------------

Future<void> _runL6() async {
  print('\n=== L6: M3u8Validator against real failure modes (expect false, no throw) ===');
  final validator = M3u8Validator(get: _liveHttpGet);

  final cases = <String, String>{
    '404 on a live host':
        'https://devstreaming-cdn.apple.com/videos/streaming/examples/does-not-exist-kazumi-live-test/master.m3u8',
    'non-playlist 200 body on a live host (path ends in .m3u8)':
        'https://httpbin.org/anything/kazumi-live-test.m3u8',
    'dead/unresolvable host':
        'https://this-host-does-not-exist.kazumi-live-test.invalid/playlist.m3u8',
  };

  for (final entry in cases.entries) {
    // validate() already catches everything internally and returns false;
    // this timeout is a belt-and-suspenders guard so a stalled connection
    // can't hang the suite, per the "generous per-call timeout" requirement.
    final result = await validator
        .validate(entry.value, {})
        .timeout(const Duration(seconds: 25));
    print('  [${entry.key}] ${entry.value} -> $result');
    expect(
      result,
      isFalse,
      reason: '${entry.key} must validate false rather than throwing',
    );
  }
}

// ---------------------------------------------------------------------------
// L7 -- build real ProbeCandidates end to end and check episodeUrl shape.
// ---------------------------------------------------------------------------

void _runL7(_L4Result? l4) {
  print('\n=== L7: build real ProbeCandidates end-to-end ===');
  if (l4 == null) {
    print('  SKIPPED: L4 produced no usable roads (upstream L2/L3/L4 failure).');
    return;
  }

  final headers = l4.plugin.buildHttpHeaders();
  var built = 0;
  for (var roadIndex = 0; roadIndex < l4.roads.length; roadIndex++) {
    final road = l4.roads[roadIndex];
    for (final href in road.data) {
      final candidate = ProbeCandidate(
        pluginName: l4.plugin.name,
        src: l4.item.src,
        episodeUrl: l4.plugin.buildFullUrl(href),
        roadIndex: roadIndex,
        useLegacyParser: l4.plugin.useLegacyParser,
        httpHeaders: headers,
      );
      final uri = Uri.tryParse(candidate.episodeUrl);
      final isAbsoluteWellFormed =
          uri != null && uri.hasScheme && uri.host.isNotEmpty;
      expect(
        isAbsoluteWellFormed,
        isTrue,
        reason: 'episodeUrl must be an absolute, well-formed URL: '
            '"${candidate.episodeUrl}" (raw href: "$href")',
      );
      built++;
    }
  }
  print('  built $built ProbeCandidate(s) from ${l4.roads.length} road(s) on '
      '"${l4.plugin.name}"; every episodeUrl is an absolute URL.');
}

String _pad(String name) => name.padRight(10);
