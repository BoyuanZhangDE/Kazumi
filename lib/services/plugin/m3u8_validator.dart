import 'package:kazumi/utils/m3u8_parser.dart';

/// Result of a plain HTTP GET, as needed by [M3u8Validator].
class HttpProbeResponse {
  final int statusCode;
  final String body;
  final String contentType;

  const HttpProbeResponse(
      {required this.statusCode, required this.body, this.contentType = ''});
}

typedef HttpProbeGetFn = Future<HttpProbeResponse> Function(
    String url, Map<String, String> headers);

/// Gate B: confirms a resolved video url is actually reachable and, for
/// m3u8, that it describes at least one real segment. Reuses [M3u8Parser]
/// rather than re-implementing playlist parsing.
class M3u8Validator {
  M3u8Validator({required HttpProbeGetFn get}) : _get = get;

  final HttpProbeGetFn _get;

  Future<bool> validate(String videoUrl, Map<String, String> headers) async {
    try {
      final response = await _get(videoUrl, headers);

      final looksLikePlaylist =
          _isM3u8Url(videoUrl) || response.body.startsWith('#EXTM3U');

      // Non-playlist responses still need sniffing: the WebView resolver's
      // DOM <video> scan can catch a poster/cover image (or an HTML error
      // page) that happens to serve 200, and status alone would wave it in.
      if (!looksLikePlaylist) {
        if (response.statusCode != 200 && response.statusCode != 206) {
          return false;
        }
        return _looksLikeMediaResponse(response);
      }

      // 206 is valid here too: the probe sends a Range header, so a
      // Range-honoring server legitimately answers Partial Content for a
      // complete-enough playlist rather than 200.
      if ((response.statusCode != 200 && response.statusCode != 206) ||
          !response.body.startsWith('#EXTM3U')) {
        return false;
      }

      if (M3u8Parser.detectType(response.body) == M3u8Type.master) {
        final master = M3u8Parser.parseMasterPlaylist(response.body, videoUrl);
        if (master.variants.isEmpty) return false;

        final variant = await _get(master.bestVariant.uri, headers);
        if (variant.statusCode != 200 && variant.statusCode != 206) {
          return false;
        }
        final playlist =
            M3u8Parser.parseMediaPlaylist(variant.body, master.bestVariant.uri);
        return playlist.segments.isNotEmpty;
      }

      final playlist = M3u8Parser.parseMediaPlaylist(response.body, videoUrl);
      return playlist.segments.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  bool _isM3u8Url(String url) {
    final path = Uri.parse(url).path.toLowerCase();
    return path.endsWith('.m3u8');
  }

  bool _looksLikeMediaResponse(HttpProbeResponse response) {
    final contentType =
        response.contentType.toLowerCase().split(';').first.trim();
    if (contentType.startsWith('image/') || contentType.startsWith('text/')) {
      return false;
    }

    final body = response.body.trim().toLowerCase();
    if (body.startsWith('<!doctype') ||
        body.startsWith('<html') ||
        body.startsWith('gif8')) {
      return false;
    }

    return true;
  }
}
