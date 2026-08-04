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

    test(
        'REGRESSION: a media playlist served 206 (Range-honoring server) '
        'passes', () async {
      final validator = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 206, body: _mediaPlaylist),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

      expect(ok, isTrue);
    });

    test(
        'REGRESSION: a master playlist served 206 whose variant fetch also '
        'returns 206 passes', () async {
      final requestedUrls = <String>[];
      final validator = M3u8Validator(
        get: (url, headers) async {
          requestedUrls.add(url);
          if (url.endsWith('master.m3u8')) {
            return HttpProbeResponse(statusCode: 206, body: _masterPlaylist);
          }
          return HttpProbeResponse(statusCode: 206, body: _mediaPlaylist);
        },
      );

      final ok = await validator.validate(
          'https://example.com/master.m3u8', const {});

      expect(ok, isTrue);
      expect(requestedUrls.length, 2,
          reason: 'the master playlist and its chosen variant should both '
              'be fetched');
    });

    test(
        '416 Range Not Satisfiable with a playlist-looking body still fails',
        () async {
      final validator = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 416, body: _mediaPlaylist),
      );

      final ok =
          await validator.validate('https://example.com/index.m3u8', const {});

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

    test(
        'REGRESSION: a cover image served 200 with image content-type fails '
        '(gugu3 false positive)', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: 'junk-binary-not-a-playlist',
          contentType: 'image/jpeg',
        ),
      );

      final ok = await validator.validate(
          'https://p9-bot-workflow-sign.byteimg.com/cover~tplv-image.image',
          const {});

      expect(ok, isFalse);
    });

    test('non-m3u8 url with video content-type passes', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: 'binary',
          contentType: 'video/mp4',
        ),
      );

      final ok =
          await validator.validate('https://example.com/video', const {});

      expect(ok, isTrue);
    });

    test('non-m3u8 url with octet-stream content-type passes', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: '\x00\x01\x02binary-ish',
          contentType: 'application/octet-stream',
        ),
      );

      final ok =
          await validator.validate('https://example.com/video', const {});

      expect(ok, isTrue);
    });

    test(
        'non-m3u8 url with empty content-type and non-HTML body passes '
        '(back-compat pin)', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: 'some-opaque-body',
          contentType: '',
        ),
      );

      final ok =
          await validator.validate('https://example.com/video', const {});

      expect(ok, isTrue);
    });

    test('non-m3u8 url with text/html content-type fails', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: 'irrelevant',
          contentType: 'text/html',
        ),
      );

      final ok =
          await validator.validate('https://example.com/video', const {});

      expect(ok, isFalse);
    });

    test(
        'non-m3u8 url with empty content-type but an HTML error body fails',
        () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: '<!DOCTYPE html><html><body>404</body></html>',
          contentType: '',
        ),
      );

      final ok =
          await validator.validate('https://example.com/video', const {});

      expect(ok, isFalse);
    });

    test(
        'a valid media playlist served from a url without a .m3u8 extension '
        'passes (extension-less playlist upgrade)', () async {
      final validator = M3u8Validator(
        get: (url, headers) async =>
            HttpProbeResponse(statusCode: 200, body: _mediaPlaylist),
      );

      final ok = await validator.validate(
          'https://example.com/playlist?token=abc', const {});

      expect(ok, isTrue);
    });

    test(
        'non-m3u8 url with mixed-case content-type and params fails '
        '(normalization pin)', () async {
      final validator = M3u8Validator(
        get: (url, headers) async => const HttpProbeResponse(
          statusCode: 200,
          body: 'irrelevant',
          contentType: 'Image/JPEG; charset=utf-8',
        ),
      );

      final ok =
          await validator.validate('https://example.com/video', const {});

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
