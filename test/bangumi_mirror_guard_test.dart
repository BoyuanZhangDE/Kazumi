import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/request/clients/bangumi_client.dart';
import 'package:kazumi/request/core/dio_factory.dart';

void main() {
  group('resolveBangumiMirrorPath', () {
    test('mirrors api.bgm.tv when proxy on and appId set', () {
      final mirrored = resolveBangumiMirrorPath(
        Uri.parse('https://api.bgm.tv/v0/subjects/1'),
        proxyEnabled: true,
        mirrorAppId: 'app-id',
      );
      expect(mirrored, 'https://api.kazumi.fyi/v0/subjects/1');
    });

    test('mirrors api.bgm.tv with query string', () {
      final mirrored = resolveBangumiMirrorPath(
        Uri.parse(
          'https://api.bgm.tv/v0/search/subjects?limit=20&offset=0',
        ),
        proxyEnabled: true,
        mirrorAppId: 'app-id',
      );
      expect(
        mirrored,
        'https://api.kazumi.fyi/v0/search/subjects?limit=20&offset=0',
      );
    });

    test('mirrors next.bgm.tv too', () {
      final mirrored = resolveBangumiMirrorPath(
        Uri.parse('https://next.bgm.tv/p1/subjects/1/comments'),
        proxyEnabled: true,
        mirrorAppId: 'app-id',
      );
      expect(mirrored, 'https://api.kazumi.fyi/p1/subjects/1/comments');
    });

    test('proxy disabled returns null', () {
      final mirrored = resolveBangumiMirrorPath(
        Uri.parse('https://api.bgm.tv/v0/subjects/1'),
        proxyEnabled: false,
        mirrorAppId: 'app-id',
      );
      expect(mirrored, isNull);
    });

    test('unrelated host returns null', () {
      final mirrored = resolveBangumiMirrorPath(
        Uri.parse('https://api.dandanplay.net/api/v2/match'),
        proxyEnabled: true,
        mirrorAppId: 'app-id',
      );
      expect(mirrored, isNull);
    });

    // REGRESSION GUARD: an unsigned build (empty mirror app id) must bypass
    // the mirror entirely, even with the proxy setting on and a mirrorable
    // host — the mirror would 401 empty credentials and break search/comments.
    test('empty appId bypasses the mirror even when proxy is on', () {
      final mirrored = resolveBangumiMirrorPath(
        Uri.parse('https://api.bgm.tv/v0/subjects/1'),
        proxyEnabled: true,
        mirrorAppId: '',
      );
      expect(mirrored, isNull);
    });
  });

  group('shouldSignProtectedMirrorRequest', () {
    test('signs POST /v0/search/subjects', () {
      expect(
        shouldSignProtectedMirrorRequest(
          url: 'https://api.bgm.tv/v0/search/subjects',
          method: 'POST',
          proxyEnabled: true,
          mirrorAppId: 'app-id',
        ),
        isTrue,
      );
    });

    test('signs GET comments on subjects/episodes/characters', () {
      for (final path in [
        '/p1/subjects/1/comments',
        '/p1/episodes/1/comments',
        '/p1/characters/1/comments',
      ]) {
        expect(
          shouldSignProtectedMirrorRequest(
            url: 'https://api.bgm.tv$path',
            method: 'GET',
            proxyEnabled: true,
            mirrorAppId: 'app-id',
          ),
          isTrue,
          reason: path,
        );
      }
    });

    test('does not sign a non-comments GET', () {
      expect(
        shouldSignProtectedMirrorRequest(
          url: 'https://api.bgm.tv/p1/subjects/1',
          method: 'GET',
          proxyEnabled: true,
          mirrorAppId: 'app-id',
        ),
        isFalse,
      );
    });

    test('does not sign a POST to another path', () {
      expect(
        shouldSignProtectedMirrorRequest(
          url: 'https://api.bgm.tv/v0/subjects',
          method: 'POST',
          proxyEnabled: true,
          mirrorAppId: 'app-id',
        ),
        isFalse,
      );
    });

    test('does not sign when proxy is off', () {
      expect(
        shouldSignProtectedMirrorRequest(
          url: 'https://api.bgm.tv/v0/search/subjects',
          method: 'POST',
          proxyEnabled: false,
          mirrorAppId: 'app-id',
        ),
        isFalse,
      );
    });

    // REGRESSION GUARD: an unsigned build (empty mirror app id) must never
    // sign, even for the search endpoint with the proxy on — the mirror
    // isn't being hit at all (see resolveBangumiMirrorPath), so signing
    // would be pointless and would also leak the empty appId in headers.
    test('empty appId never signs, even for search subjects', () {
      expect(
        shouldSignProtectedMirrorRequest(
          url: 'https://api.bgm.tv/v0/search/subjects',
          method: 'POST',
          proxyEnabled: true,
          mirrorAppId: '',
        ),
        isFalse,
      );
    });
  });
}
