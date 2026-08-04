// Live, real-network verification for the DanDanPlay danmaku integration
// (lib/request/apis/danmaku_api.dart), which hits the real
// api.dandanplay.net using the signed-request scheme in lib/utils/crypto.dart.
//
//   flutter test                                          # default: skipped, zero network
//   flutter test --tags live --run-skipped                # opt in, no creds -> auth-failure case only
//   flutter test --tags live --run-skipped \
//     --dart-define-from-file=dart_defines/local.json      # opt in, with creds -> full chain
//
// (See dart_test.yaml at the repo root for why `--run-skipped` -- not just
// `--tags live` -- is the actual opt-in command.)
//
// This file is DIAGNOSTIC, not a correctness gate: comment counts and other
// remote-availability facts are PRINTED, never asserted, so "the internet is
// broken today" (or DanDanPlay's catalog changing) never turns a red build.
// Only our own invariants are asserted:
//   - missing/invalid credentials produce a typed NetworkException (a 403
//     surfaces as `badResponse`), never a hang or an unhandled throw.
//   - with real credentials compiled in, the search -> resolve bangumi id ->
//     episodes -> comments chain runs through DanmakuApi without throwing.
//
// DanmakuApi ultimately calls DioFactory.apiDio, which reads proxy settings
// via NetworkConfig.fromSettings() -> GStorage.getSetting() -- a Hive box
// that only exists once GStorage.init() has run. setUpAll below boots
// GStorage against an isolated temp directory (mirrors the boot pattern in
// test/live/live_source_verification_test.dart) purely so this opt-in suite
// can make real calls; it never touches the app's actual storage.
@Tags(['live'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:kazumi/request/apis/danmaku_api.dart';
import 'package:kazumi/request/core/network_exception.dart';
import 'package:kazumi/services/storage/storage.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Popular, long-running show with a large comment library -- good signal
/// for "did this actually work" beyond just "did it not throw".
const _targetTitle = '孤独摇滚';

/// Whether real credentials were baked in via --dart-define(-from-file). The
/// default `flutter test` (and a plain `--tags live --run-skipped` without
/// --dart-define-from-file) compiles this to an empty string.
const _appId = String.fromEnvironment('DANDANAPI_APPID');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // TestWidgetsFlutterBinding installs an HttpOverrides that fakes every
  // HttpClient to return 400 without touching the network -- a safety net
  // for widget tests that never intend to make real requests. This suite's
  // entire point is real requests, so it must be turned back off.
  HttpOverrides.global = null;

  late Directory tempStorageDir;

  setUpAll(() async {
    tempStorageDir = await Directory.systemTemp
        .createTemp('kazumi_danmaku_live_test_storage_');
    PathProviderPlatform.instance =
        _FakePathProviderPlatform(tempStorageDir.path);
    Hive.init('${tempStorageDir.path}/hive');
    await GStorage.init();
  });

  tearDownAll(() async {
    if (await tempStorageDir.exists()) {
      await tempStorageDir.delete(recursive: true);
    }
  });

  test(
    'missing/empty credentials surface as a typed auth failure, not a hang',
    () async {
      if (_appId.isNotEmpty) {
        print('\n=== SKIPPED: DANDANAPI_APPID is compiled in for this run; '
            'this case only exercises the empty-credential path ===');
        return;
      }
      print('\n=== DanDanPlay auth-failure invariant (empty credentials) ===');
      try {
        final response =
            await DanmakuApi.getDanmakuSearchResponse('kazumi-live-test')
                .timeout(const Duration(seconds: 20));
        // If DanDanPlay ever allows unauthenticated search there is nothing
        // to assert about failure -- just report it, don't fail the build.
        print('  unexpected success with empty credentials: '
            '${response.animes.length} anime(s)');
      } on NetworkException catch (e) {
        print('  -> NetworkException(type=${e.type}, '
            'statusCode=${e.statusCode})');
        expect(
          e.type,
          NetworkExceptionType.badResponse,
          reason: 'empty/invalid credentials are expected to 403 and surface '
              'as a badResponse NetworkException, not a hang or a raw throw',
        );
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'search -> resolve bangumi id -> episodes -> comments (real creds)',
    () async {
      if (_appId.isEmpty) {
        print('\n=== SKIPPED: DANDANAPI_APPID not compiled in. Run with:\n'
            '  flutter test test/live/danmaku_live_test.dart --tags live '
            '--run-skipped \\\n'
            '    --dart-define-from-file=dart_defines/local.json ===');
        return;
      }

      print('\n=== search "$_targetTitle" ===');
      final searchResponse =
          await DanmakuApi.getDanmakuSearchResponse(_targetTitle)
              .timeout(const Duration(seconds: 20));
      print('  success=${searchResponse.success} '
          'errorCode=${searchResponse.errorCode} '
          '${searchResponse.animes.length} anime(s)');
      for (final anime in searchResponse.animes.take(5)) {
        print('    animeId=${anime.animeId} "${anime.animeTitle}" '
            'episodes=${anime.episodeCount}');
      }
      expect(
        searchResponse.animes,
        isNotEmpty,
        reason: 'expected at least one DanDanPlay search hit for a '
            'popular, well-known show title',
      );

      final bangumiId = await DanmakuApi.getBangumiIDByTitle(_targetTitle)
          .timeout(const Duration(seconds: 20));
      print('\n=== resolved bangumiId=$bangumiId ===');
      expect(
        bangumiId,
        greaterThan(0),
        reason: 'expected to resolve a real DanDanPlay anime id for a title '
            'that just produced search hits',
      );

      // Note: getBangumiIDByTitle resolves a DanDanPlay-native anime id, not
      // a Bangumi.tv id, so the DanDan-native lookup
      // (getDanDanEpisodesByDanDanBangumiID -> /api/v2/bangumi/{id}) is the
      // correct next call here -- getDanmakuEpisodesByBangumiID hits
      // /api/v2/bangumi/bgmtv/{id} and expects a Bangumi.tv id instead.
      final episodesResponse =
          await DanmakuApi.getDanDanEpisodesByDanDanBangumiID(bangumiId)
              .timeout(const Duration(seconds: 20));
      print('\n=== episodes for bangumiId=$bangumiId ===');
      print('  success=${episodesResponse.success} '
          '${episodesResponse.episodes.length} episode(s)');
      expect(
        episodesResponse.episodes,
        isNotEmpty,
        reason: 'expected at least one episode for a resolved bangumi id',
      );

      final firstEpisode = episodesResponse.episodes.first;
      print('  first episode: id=${firstEpisode.episodeId} '
          '"${firstEpisode.episodeTitle}"');

      final comments =
          await DanmakuApi.getDanDanmakuByEpisodeID(firstEpisode.episodeId)
              .timeout(const Duration(seconds: 20));
      print('\n=== comments for episodeId=${firstEpisode.episodeId} ===');
      print('  ${comments.length} comment(s)');
      if (comments.isNotEmpty) {
        print('  sample: "${comments.first.message}"');
      }
      expect(
        comments,
        isNotEmpty,
        reason: 'expected at least one danmaku comment for episode 1 of a '
            'popular, long-running show',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
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
