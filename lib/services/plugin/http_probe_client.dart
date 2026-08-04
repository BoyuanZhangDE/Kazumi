import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/plugin/m3u8_validator.dart';

/// A direct-media winner (e.g. a bare .mp4) would otherwise be downloaded in
/// full just to be probed — 397MB measured live on a real race winner. This
/// is far past anything a playlist needs to parse, and plenty for magic-byte
/// / HTML sniffing.
const int probeCapBytes = 64 * 1024;

/// Thin [HttpProbeGetFn] adapter over the app's Dio client. All validation
/// logic lives in [M3u8Validator] — this only performs the GET and reports
/// the raw status/body, accepting any status code so gate B can inspect it.
///
/// The body is streamed and capped at [probeCapBytes]: servers that honor
/// the `Range` header make this cheap over the wire, and the client-side cap
/// in [readCapped] is what keeps it correct when they don't.
Future<HttpProbeResponse> httpProbeGet(
  String url,
  Map<String, String> headers,
) async {
  final response = await DioFactory.downloadDio.get<ResponseBody>(
    url,
    options: Options(
      headers: buildProbeHeaders(headers),
      responseType: ResponseType.stream,
      validateStatus: (_) => true,
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
  final bytes = await readCapped(response.data!.stream, probeCapBytes);
  return HttpProbeResponse(
    statusCode: response.statusCode ?? 0,
    // allowMalformed: the capped bytes may be binary media, or may cut a
    // multi-byte UTF-8 sequence in half at the cap boundary — never throw.
    body: utf8.decode(bytes, allowMalformed: true),
    contentType: response.headers.value('content-type') ?? '',
  );
}

/// Reads at most [cap] bytes from [source], then stops consuming. Breaking
/// out of an `await for` cancels the underlying subscription, which
/// releases the connection instead of draining a possibly-huge remainder.
Future<List<int>> readCapped(Stream<List<int>> source, int cap) async {
  final bytes = <int>[];
  await for (final chunk in source) {
    bytes.addAll(chunk);
    if (bytes.length >= cap) break;
  }
  return bytes.length > cap ? bytes.sublist(0, cap) : bytes;
}

/// Merges a `Range: bytes=0-<cap-1>` request onto [callerHeaders], unless
/// the caller already set a Range header — an explicit caller choice is
/// never clobbered.
Map<String, String> buildProbeHeaders(Map<String, String> callerHeaders) {
  final hasRange = callerHeaders.keys.any((k) => k.toLowerCase() == 'range');
  if (hasRange) return callerHeaders;
  return {
    ...callerHeaders,
    'Range': 'bytes=0-${probeCapBytes - 1}',
  };
}
