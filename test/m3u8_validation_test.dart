import 'package:flutter_test/flutter_test.dart';
import 'package:kazumi/services/plugin/m3u8_validator.dart';

void main() {
  group('M3u8Validator', () {
    test('media playlist: 200 + #EXTM3U body with segments passes', () async {
      final validator = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 200, body: _mediaPlaylist),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

      expect(ok, isTrue);
    });

    test('403 response fails validation', () async {
      final validator = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 403, body: ''),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

      expect(ok, isFalse);
    });

    test('200 but an empty/segment-less playlist fails', () async {
      final validator = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 200, body: _emptyMediaPlaylist),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

      expect(ok, isFalse);
    });

    test('200 but body is not a playlist fails', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => HttpProbeResponse(
          statusCode: 200,
          body: '<html><body>404 Not Found</body></html>',
        ),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

      expect(ok, isFalse);
    });

    test('master playlist resolves a variant and passes when it has segments',
        () async {
      final requestedUrls = <String>[];
      final validator = M3u8Validator(
        get: (url, headers) async {
          requestedUrls.add(url);
          if (url.endsWith('master.m3u8')) {
            return HttpProbeResponse(statusCode: 200, body: _masterPlaylist);
          }
          return HttpProbeResponse(statusCode: 200, body: _mediaPlaylist);
        },
      );

      final ok = await validator.validate(
          'https://example.com/master.m3u8', const {});

      expect(ok, isTrue);
      expect(requestedUrls.length, 2,
          reason: 'the master playlist and its chosen variant should both '
              'be fetched');
    });

    test('master playlist fails when the resolved variant is empty',
        () async {
      final validator = M3u8Validator(
        get: (url, headers) async {
          if (url.endsWith('master.m3u8')) {
            return HttpProbeResponse(statusCode: 200, body: _masterPlaylist);
          }
          return HttpProbeResponse(
              statusCode: 200, body: _emptyMediaPlaylist);
        },
      );

      final ok = await validator.validate(
          'https://example.com/master.m3u8', const {});

      expect(ok, isFalse);
    });

    test('non-m3u8 url passes on 200 or 206 and fails on 404', () async {
      final validator200 = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 200, body: ''),
      );
      expect(
          await validator200.validate(
              'https://example.com/video.mp4', const {}),
          isTrue);

      final validator206 = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 206, body: ''),
      );
      expect(
          await validator206.validate(
              'https://example.com/video.mp4', const {}),
          isTrue);

      final validator404 = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 404, body: ''),
      );
      expect(
          await validator404.validate(
              'https://example.com/video.mp4', const {}),
          isFalse);
    });

    test('a getter that throws is treated as a failed validation, not a crash',
        () async {
      final validator = M3u8Validator(
        get: (url, headers) async => throw Exception('network error'),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

      expect(ok, isFalse);
    });
  });
}

const _mediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:0
#EXTINF:10.0,
seg_00000.ts
#EXTINF:10.0,
seg_00001.ts
#EXT-X-ENDLIST
''';

const _emptyMediaPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-PLAYLIST-TYPE:VOD
#EXT-X-TARGETDURATION:10
''';

const _masterPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=836280,RESOLUTION=848x480
variant.m3u8
''';
