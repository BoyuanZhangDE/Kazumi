import 'package:dio/dio.dart';
import 'package:kazumi/request/core/dio_factory.dart';
import 'package:kazumi/services/plugin/m3u8_validator.dart';

/// Thin [HttpProbeGetFn] adapter over the app's Dio client. All validation
/// logic lives in [M3u8Validator] — this only performs the GET and reports
/// the raw status/body, accepting any status code so gate B can inspect it.
Future<HttpProbeResponse> httpProbeGet(
  String url,
  Map<String, String> headers,
) async {
  final response = await DioFactory.downloadDio.get<String>(
    url,
    options: Options(
      headers: headers,
      responseType: ResponseType.plain,
      validateStatus: (_) => true,
      receiveTimeout: const Duration(seconds: 10),
    ),
  );
  return HttpProbeResponse(
    statusCode: response.statusCode ?? 0,
    body: response.data ?? '',
  );
}
